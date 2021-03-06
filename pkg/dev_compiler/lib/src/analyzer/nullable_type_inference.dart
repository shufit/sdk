// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/standard_resolution_map.dart';
import 'package:analyzer/dart/ast/token.dart' show TokenType;
import 'package:analyzer/dart/ast/visitor.dart' show RecursiveAstVisitor;
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'element_helpers.dart' show getStaticType, isInlineJS, findAnnotation;
import 'js_interop.dart' show isNotNullAnnotation, isNullCheckAnnotation;
import 'js_typerep.dart';
import 'property_model.dart';

/// An inference engine for nullable types.
///
/// This can answer questions about whether expressions are nullable
/// (see [isNullable]). Given a set of compilation units in a library, it will
/// determine if locals can be null using flow-insensitive analysis.
///
/// The analysis for null expressions is conservative and incomplete, but it can
/// optimize some patterns.
// TODO(vsm): Revisit whether we really need this when we get
// better non-nullability in the type system.
abstract class NullableTypeInference {
  LibraryElement get coreLibrary;
  VirtualFieldModel get virtualFields;

  JSTypeRep get jsTypeRep;
  bool isObjectMember(String name);

  /// Known non-null local variables.
  HashSet<LocalVariableElement> _notNullLocals;

  void inferNullableTypes(AstNode node) {
    var visitor = _NullableLocalInference(this);
    node.accept(visitor);
    _notNullLocals = visitor.computeNotNullLocals();
  }

  /// Adds a new variable, typically a compiler generated temporary, and record
  /// whether its type is nullable.
  void addTemporaryVariable(LocalVariableElement local,
      {bool nullable = true}) {
    if (!nullable) _notNullLocals.add(local);
  }

  /// Returns true if [expr] can be null.
  bool isNullable(Expression expr) => _isNullable(expr);

  bool _isNonNullMethodInvocation(MethodInvocation expr) {
    // TODO(vsm): This logic overlaps with the resolver.
    // Where is the best place to put this?
    var e = resolutionMap.staticElementForIdentifier(expr.methodName);
    if (e == null) return false;
    if (isInlineJS(e)) {
      // Fix types for JS builtin calls.
      //
      // This code was taken from analyzer. It's not super sophisticated:
      // only looks for the type name in dart:core, so we just copy it here.
      //
      // TODO(jmesserly): we'll likely need something that can handle a wider
      // variety of types, especially when we get to JS interop.
      var args = expr.argumentList.arguments;
      var first = args.isNotEmpty ? args.first : null;
      if (first is SimpleStringLiteral) {
        var types = first.stringValue;
        if (types != '' &&
            types != 'var' &&
            !types.split('|').contains('Null')) {
          return true;
        }
      }
    }

    if (e.name == 'identical' && identical(e.library, coreLibrary)) {
      return true;
    }
    // If this is a method call, check to see whether it is to a final
    // type for which we have a known implementation type (i.e. int, bool,
    // double, and String), and if so use the element for the implementation
    // type instead.
    if (e is MethodElement) {
      Element container = e.enclosingElement;
      if (container is ClassElement) {
        DartType targetType = container.type;
        InterfaceType implType = jsTypeRep.getImplementationType(targetType);
        if (implType != null) {
          MethodElement method = implType.lookUpMethod(e.name, coreLibrary);
          if (method != null) e = method;
        }
      }
    }
    // If the method or function is annotated as returning a non-null value
    // then the result of the call is non-null.
    return (e is MethodElement || e is FunctionElement) && _assertedNotNull(e);
  }

  bool _isNonNullProperty(Element element, String name) {
    if (element is! PropertyInducingElement &&
        element is! PropertyAccessorElement) {
      return false;
    }
    // If this is a reference to an element of a type for which
    // we have a known implementation type (i.e. int, double,
    // bool, String), then use the element for the implementation
    // type.
    Element container = element.enclosingElement;
    if (container is ClassElement) {
      var targetType = container.type;
      var implType = jsTypeRep.getImplementationType(targetType);
      if (implType != null) {
        var getter = implType.lookUpGetter(name, coreLibrary);
        if (getter != null) element = getter;
      }
    }
    // If the getter is a synthetic element, then any annotations will
    // be on the variable, so use those instead.
    if (element is PropertyAccessorElement && element.isSynthetic) {
      return _assertedNotNull(element.variable);
    }
    // Return true if the element is annotated as returning a non-null value.
    return _assertedNotNull(element);
  }

  /// Returns true if [expr] can be null, optionally using [localIsNullable]
  /// for locals.
  ///
  /// If [localIsNullable] is not supplied, this will use the known list of
  /// [_notNullLocals].
  bool _isNullable(Expression expr,
      [bool localIsNullable(LocalVariableElement e)]) {
    // TODO(jmesserly): we do recursive calls in a few places. This could
    // leads to O(depth) cost for calling this function. We could store the
    // resulting value if that becomes an issue, so we maintain the invariant
    // that each node is visited once.
    Element element = null;
    String name = null;
    if (expr is PropertyAccess &&
        expr.operator?.type != TokenType.QUESTION_PERIOD) {
      element = expr.propertyName.staticElement;
      name = expr.propertyName.name;
    } else if (expr is PrefixedIdentifier) {
      element = expr.staticElement;
      name = expr.identifier.name;
    } else if (expr is Identifier) {
      element = expr.staticElement;
      name = expr.name;
    }
    if (element != null) {
      if (_isNonNullProperty(element, name)) return false;

      // Type literals are not null.
      if (element is ClassElement || element is FunctionTypeAliasElement) {
        return false;
      }

      if (element is LocalVariableElement) {
        if (localIsNullable != null) {
          return localIsNullable(element);
        }
        return !_notNullLocals.contains(element);
      }

      if (element is ParameterElement && _assertedNotNull(element)) {
        return false;
      }

      if (element is FunctionElement || element is MethodElement) {
        // A function or method. This can't be null.
        return false;
      }

      if (element is PropertyAccessorElement && element.isGetter) {
        PropertyInducingElement variable = element.variable;
        if (variable is FieldElement && virtualFields.isVirtual(variable)) {
          return true;
        }
        var value = variable.computeConstantValue();
        return value == null || value.isNull || !value.hasKnownValue;
      }

      // Other types of identifiers are nullable (parameters, fields).
      return true;
    }

    if (expr is Literal) return expr is NullLiteral;
    if (expr is IsExpression) return false;
    if (expr is FunctionExpression) return false;
    if (expr is ThisExpression) return false;
    if (expr is SuperExpression) return false;
    if (expr is CascadeExpression) {
      // Cascades normally can't return `null`, because if the target is null,
      // they will throw noSuchMethod.
      // The only properties/methods on `null` are those on Object itself.
      for (var section in expr.cascadeSections) {
        Element e = null;
        if (section is PropertyAccess) {
          e = section.propertyName.staticElement;
        } else if (section is MethodInvocation) {
          e = section.methodName.staticElement;
        } else if (section is IndexExpression) {
          // Object does not have operator []=.
          return false;
        }
        // We encountered a non-Object method/property.
        if (e != null && !isObjectMember(e.name)) {
          return false;
        }
      }
      return _isNullable(expr.target, localIsNullable);
    }
    if (expr is ConditionalExpression) {
      return _isNullable(expr.thenExpression, localIsNullable) ||
          _isNullable(expr.elseExpression, localIsNullable);
    }
    if (expr is ParenthesizedExpression) {
      return _isNullable(expr.expression, localIsNullable);
    }
    if (expr is InstanceCreationExpression) {
      var e = resolutionMap.staticElementForConstructorReference(expr);
      if (e == null) return true;

      // Follow redirects.
      while (e.redirectedConstructor != null) {
        e = e.redirectedConstructor;
      }

      // Generative constructors are not nullable.
      if (!e.isFactory) return false;

      // Factory constructors are nullable. However it is a bad pattern and
      // our own SDK will never do this.
      // TODO(jmesserly): we could enforce this for user-defined constructors.
      if (e.library.source.isInSystemLibrary) return false;

      return true;
    }
    if (expr is MethodInvocation &&
        (expr.operator?.lexeme != '?.' ||
            !_isNullable(expr.target, localIsNullable)) &&
        _isNonNullMethodInvocation(expr)) {
      return false;
    }

    Expression operand, rightOperand;
    String op;
    if (expr is AssignmentExpression) {
      op = expr.operator.lexeme;
      assert(op.endsWith('='));
      if (op == '=') {
        return _isNullable(expr.rightHandSide, localIsNullable);
      }
      // op assignment like +=, remove trailing '='
      op = op.substring(0, op.length - 1);
      operand = expr.leftHandSide;
      rightOperand = expr.rightHandSide;
    } else if (expr is BinaryExpression) {
      operand = expr.leftOperand;
      rightOperand = expr.rightOperand;
      op = expr.operator.lexeme;
    } else if (expr is PrefixExpression) {
      operand = expr.operand;
      op = expr.operator.lexeme;
    } else if (expr is PostfixExpression) {
      operand = expr.operand;
      op = expr.operator.lexeme;
    }
    switch (op) {
      case '==':
      case '!=':
      case '&&':
      case '||':
      case '!':
        return false;
      case '??':
        return _isNullable(operand, localIsNullable) &&
            _isNullable(rightOperand, localIsNullable);
    }
    if (operand != null && jsTypeRep.isPrimitive(getStaticType(operand))) {
      return false;
    }

    // TODO(ochafik,jmesserly): handle other cases such as: refs to top-level
    // finals that have been assigned non-nullable values.

    // Failed to recognize a non-nullable case: assume it can be null.
    return true;
  }
}

/// A visitor that determines which local variables are non-nullable.
///
/// This will consider all assignments to local variables using
/// flow-insensitive inference. That information is used to determine which
/// variables are nullable in the given scope.
// TODO(ochafik): Introduce flow analysis (a variable may be nullable in
// some places and not in others).
class _NullableLocalInference extends RecursiveAstVisitor {
  final NullableTypeInference _nullInference;

  /// Known local variables.
  final _locals = HashSet<LocalVariableElement>.identity();

  /// Variables that are known to be nullable.
  final _nullableLocals = HashSet<LocalVariableElement>.identity();

  /// Given a variable, tracks all other variables that it is assigned to.
  final _assignments =
      HashMap<LocalVariableElement, Set<LocalVariableElement>>.identity();

  _NullableLocalInference(this._nullInference);

  /// After visiting nodes, this can be called to compute the set of not-null
  /// locals.
  ///
  /// This method must only be called once. After it is called, the visitor
  /// should be discarded.
  HashSet<LocalVariableElement> computeNotNullLocals() {
    // Given a set of variables that are nullable, remove them from our list of
    // local variables. The end result of this process is a list of variables
    // known to be not null.
    visitNullableLocal(LocalVariableElement e) {
      _locals.remove(e);

      // Visit all other locals that this one is assigned to, and record that
      // they are nullable too.
      _assignments.remove(e)?.forEach(visitNullableLocal);
    }

    _nullableLocals.forEach(visitNullableLocal);

    // Any remaining locals are non-null.
    return _locals;
  }

  @override
  visitVariableDeclaration(VariableDeclaration node) {
    var element = node.element;
    var initializer = node.initializer;
    if (element is LocalVariableElement) {
      _locals.add(element);
      if (initializer != null) {
        _visitAssignment(node.name, initializer);
      } else if (!_assertedNotNull(element)) {
        _nullableLocals.add(element);
      }
    }
    super.visitVariableDeclaration(node);
  }

  @override
  visitForEachStatement(ForEachStatement node) {
    if (node.identifier == null) {
      var declaration = node.loopVariable;
      var element = declaration.element;
      _locals.add(element);
      if (!_assertedNotNull(element)) {
        _nullableLocals.add(element);
      }
    } else {
      var element = node.identifier.staticElement;
      if (element is LocalVariableElement && !_assertedNotNull(element)) {
        _nullableLocals.add(element);
      }
    }
    super.visitForEachStatement(node);
  }

  @override
  visitCatchClause(CatchClause node) {
    var e = node.exceptionParameter?.staticElement;
    if (e is LocalVariableElement) {
      _locals.add(e);
      // TODO(jmesserly): we allow throwing of `null`, for better or worse.
      _nullableLocals.add(e);
    }

    e = node.stackTraceParameter?.staticElement;
    if (e is LocalVariableElement) _locals.add(e);

    super.visitCatchClause(node);
  }

  @override
  visitAssignmentExpression(AssignmentExpression node) {
    if (node.operator.lexeme == '=') {
      _visitAssignment(node.leftHandSide, node.rightHandSide);
    } else {
      _visitAssignment(node.leftHandSide, node);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  visitPostfixExpression(PostfixExpression node) {
    var op = node.operator.type;
    if (op.isIncrementOperator) {
      _visitAssignment(node.operand, node);
    }
    super.visitPostfixExpression(node);
  }

  @override
  visitPrefixExpression(PrefixExpression node) {
    var op = node.operator.type;
    if (op.isIncrementOperator) {
      _visitAssignment(node.operand, node);
    }
    super.visitPrefixExpression(node);
  }

  void _visitAssignment(Expression left, Expression right) {
    if (left is SimpleIdentifier) {
      var element = left.staticElement;
      if (element is LocalVariableElement && !_assertedNotNull(element)) {
        bool visitLocal(LocalVariableElement otherLocal) {
          // Record the assignment.
          _assignments
              .putIfAbsent(otherLocal, () => HashSet.identity())
              .add(element);
          // Optimistically assume this local is not null.
          // We will validate this assumption later.
          return false;
        }

        if (_nullInference._isNullable(right, visitLocal)) {
          _nullableLocals.add(element);
        }
      }
    }
  }
}

bool _assertedNotNull(Element e) =>
    findAnnotation(e, isNotNullAnnotation) != null ||
    findAnnotation(e, isNullCheckAnnotation) != null;
