// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:meta/meta.dart';

/// Data structure to keep track of the relationship between [NullabilityNode]
/// objects.
class NullabilityGraph {
  /// Set containing all [NullabilityNode]s that have been passed as the
  /// `sourceNode` argument to [connect].
  final _allSourceNodes = Set<NullabilityNode>.identity();

  /// List of [_NullabilityEdge] objects that are downstream from
  /// [NullabilityNode.always].  (They can't be stored in
  /// [NullabilityNode.always] directly because it is immutable).
  final _downstreamFromAlways = <_NullabilityEdge>[];

  /// List of [NullabilityNodes] that are "upstream" from
  /// [NullabilityNode.never] due to unconditional control flow.  (They can't be
  /// stored in [NullabilityNode.never] directly because it is immutable).
  final _unconditionalUpstreamFromNever = <NullabilityNode>[];

  /// Records that [sourceNode] is immediately upstream from [destinationNode].
  void connect(NullabilityNode sourceNode, NullabilityNode destinationNode,
      {bool unconditional: false, List<NullabilityNode> guards: const []}) {
    var sources = [sourceNode]..addAll(guards);
    var edge = _NullabilityEdge(destinationNode, sources);
    for (var source in sources) {
      _allSourceNodes.add(source);
      if (source is NullabilityNodeMutable) {
        source._downstreamEdges.add(edge);
      } else if (source == NullabilityNode.always) {
        _downstreamFromAlways.add(edge);
      } else {
        // We don't need to track nodes that are downstream from `never` because
        // `never` will never be nullable.
        assert(source == NullabilityNode.never);
      }
    }
    if (unconditional) {
      if (destinationNode is NullabilityNodeMutable) {
        destinationNode._unconditionalUpstreamNodes.add(sourceNode);
      } else if (destinationNode == NullabilityNode.never) {
        _unconditionalUpstreamFromNever.add(sourceNode);
      } else {
        // We don't need to track nodes that are upstream from `always` because
        // `always` will never have non-null intent.
        assert(destinationNode == NullabilityNode.always);
      }
    }
  }

  void debugDump() {
    for (var source in _allSourceNodes) {
      var edges = _getDownstreamEdges(source);
      var destinations =
          edges.where((edge) => edge.primarySource == source).map((edge) {
        var suffixes = <Object>[];
        if (getUnconditionalUpstreamNodes(edge.destinationNode)
            .contains(source)) {
          suffixes.add('unconditional');
        }
        suffixes.addAll(edge.guards);
        var suffix = suffixes.isNotEmpty ? ' (${suffixes.join(', ')})' : '';
        return '${edge.destinationNode}$suffix';
      });
      var suffixes = <String>[];
      if (source.isNullable) {
        suffixes.add('nullable');
      }
      if (source.hasNonNullIntent) {
        suffixes.add('non-null intent');
      }
      var suffix = suffixes.isNotEmpty ? ' (${suffixes.join(', ')})' : '';
      print('$source$suffix -> ${destinations.join(', ')}');
    }
  }

  /// Iterates through all nodes that are "downstream" of [node] (i.e. if
  /// [node] is nullable, then all the iterated nodes will either have to be
  /// nullable, or null checks will have to be added).
  ///
  /// There is no guarantee of uniqueness of the iterated nodes.
  Iterable<NullabilityNode> getDownstreamNodes(NullabilityNode node) =>
      _getDownstreamEdges(node)
          .where((edge) => edge.primarySource == node)
          .map((edge) => edge.destinationNode);

  /// Iterates through all nodes that are "upstream" of [node] due to
  /// unconditional control flow.
  ///
  /// There is no guarantee of uniqueness of the iterated nodes.
  Iterable<NullabilityNode> getUnconditionalUpstreamNodes(
      NullabilityNode node) {
    if (node is NullabilityNodeMutable) {
      return node._unconditionalUpstreamNodes;
    } else if (node == NullabilityNode.never) {
      return _unconditionalUpstreamFromNever;
    } else {
      // No nodes are upstream from `always`.
      assert(node == NullabilityNode.always);
      return const [];
    }
  }

  /// Iterates through all nodes that are "upstream" of [node] (i.e. if
  /// any of the iterated nodes are nullable, then [node] will either have to be
  /// nullable, or null checks will have to be added).
  ///
  /// There is no guarantee of uniqueness of the iterated nodes.
  ///
  /// This method is inefficent since it has to search the entire graph, so it
  /// is for testing only.
  @visibleForTesting
  Iterable<NullabilityNode> getUpstreamNodesForTesting(
      NullabilityNode node) sync* {
    for (var source in _allSourceNodes) {
      for (var edge in _getDownstreamEdges(source)) {
        if (edge.destinationNode == node) {
          yield source;
        }
      }
    }
  }

  /// Determines the nullability of each node in the graph by propagating
  /// nullability information from one node to another.
  void propagate() {
    _propagateUpstream();
    _propagateDownstream();
  }

  Iterable<_NullabilityEdge> _getDownstreamEdges(NullabilityNode node) {
    if (node is NullabilityNodeMutable) {
      return node._downstreamEdges;
    } else if (node == NullabilityNode.always) {
      return _downstreamFromAlways;
    } else {
      // No nodes are downstream from `never`.
      assert(node == NullabilityNode.never);
      return const [];
    }
  }

  /// Propagates nullability downstream.
  void _propagateDownstream() {
    var pendingEdges = <_NullabilityEdge>[]..addAll(_downstreamFromAlways);
    var pendingSubstitutions = <NullabilityNodeForSubstitution>[];
    while (true) {
      nextEdge:
      while (pendingEdges.isNotEmpty) {
        var edge = pendingEdges.removeLast();
        var node = edge.destinationNode;
        if (node.hasNonNullIntent) {
          // Non-null intent nodes are never made nullable; a null check will need
          // to be added instead.
          continue;
        }
        for (var source in edge.sources) {
          if (!source.isNullable) {
            // Note all sources are nullable, so this edge doesn't apply yet.
            continue nextEdge;
          }
        }
        if (node is NullabilityNodeMutable && node._becomeNullable()) {
          // Was not previously nullable, so we need to propagate.
          pendingEdges.addAll(node._downstreamEdges);
          if (node is NullabilityNodeForSubstitution) {
            pendingSubstitutions.add(node);
          }
        }
      }
      if (pendingSubstitutions.isEmpty) break;
      var node = pendingSubstitutions.removeLast();
      if (node.innerNode.isNullable || node.outerNode.isNullable) {
        // No further propagation is needed, since some other connection already
        // propagated nullability to either the inner or outer node.
        continue;
      }
      // Heuristically choose to propagate to the inner node since this seems
      // to lead to better quality migrations.
      pendingEdges.add(_NullabilityEdge(node.innerNode, const []));
    }
  }

  /// Propagates non-null intent upstream along unconditional control flow
  /// lines.
  void _propagateUpstream() {
    var pendingNodes = <NullabilityNode>[]
      ..addAll(_unconditionalUpstreamFromNever);
    while (pendingNodes.isNotEmpty) {
      var node = pendingNodes.removeLast();
      if (node == NullabilityNode.always) {
        // The "always" node cannot have non-null intent.
        continue;
      }
      if (node is NullabilityNodeMutable && node._setNonNullIntent()) {
        // Was not previously in the set of non-null intent nodes, so we need to
        // propagate.
        pendingNodes.addAll(node._unconditionalUpstreamNodes);
      }
    }
  }
}

/// Representation of a single node in the nullability inference graph.
///
/// Initially, this is just a wrapper over constraint variables, and the
/// nullability inference graph is encoded into the wrapped constraint
/// variables.  Over time this will be replaced by a first class representation
/// of the nullability inference graph.
abstract class NullabilityNode {
  /// [NullabilityNode] used for types that are known a priori to be nullable
  /// (e.g. the type of the `null` literal).
  static final NullabilityNode always =
      _NullabilityNodeImmutable('always', true);

  /// [NullabilityNode] used for types that are known a priori to be
  /// non-nullable (e.g. the type of an integer literal).
  static final NullabilityNode never =
      _NullabilityNodeImmutable('never', false);

  static final _debugNamesInUse = Set<String>();

  bool _isPossiblyOptional = false;

  String _debugName;

  /// Creates a [NullabilityNode] representing the nullability of a variable
  /// whose type is `dynamic` due to type inference.
  ///
  /// TODO(paulberry): this should go away; we should decorate the actual
  /// inferred type rather than assuming `dynamic`.
  factory NullabilityNode.forInferredDynamicType(
      NullabilityGraph graph, int offset) {
    var node = _NullabilityNodeSimple('inferredDynamic($offset)');
    graph.connect(NullabilityNode.always, node, unconditional: true);
    return node;
  }

  /// Creates a [NullabilityNode] representing the nullability of an
  /// expression which is nullable iff both [a] and [b] are nullable.
  ///
  /// The constraint variable contained in the new node is created using the
  /// [joinNullabilities] callback.  TODO(paulberry): this should become
  /// unnecessary once constraint solving is performed directly using
  /// [NullabilityNode] objects.
  factory NullabilityNode.forLUB(
      Expression conditionalExpression,
      NullabilityNode a,
      NullabilityNode b,
      NullabilityGraph graph) = NullabilityNodeForLUB._;

  /// Creates a [NullabilityNode] representing the nullability of a type
  /// substitution where [outerNode] is the nullability node for the type
  /// variable being eliminated by the substitution, and [innerNode] is the
  /// nullability node for the type being substituted in its place.
  ///
  /// [innerNode] may be `null`.  TODO(paulberry): when?
  ///
  /// Additional constraints are recorded in [constraints] as necessary to make
  /// the new nullability node behave consistently with the old nodes.
  /// TODO(paulberry): this should become unnecessary once constraint solving is
  /// performed directly using [NullabilityNode] objects.
  factory NullabilityNode.forSubstitution(
          NullabilityNode innerNode, NullabilityNode outerNode) =
      NullabilityNodeForSubstitution._;

  /// Creates a [NullabilityNode] representing the nullability of a type
  /// annotation appearing explicitly in the user's program.
  factory NullabilityNode.forTypeAnnotation(int endOffset,
          {@required bool always}) =>
      _NullabilityNodeSimple('type($endOffset)');

  NullabilityNode._();

  /// Gets a string that can be appended to a type name during debugging to help
  /// annotate the nullability of that type.
  String get debugSuffix =>
      this == always ? '?' : this == never ? '' : '?($this)';

  bool get hasNonNullIntent;

  /// After nullability propagation, this getter can be used to query whether
  /// the type associated with this node should be considered nullable.
  bool get isNullable;

  /// Indicates whether this node is associated with a named parameter for which
  /// nullability migration needs to decide whether it is optional or required.
  bool get isPossiblyOptional => _isPossiblyOptional;

  String get _debugPrefix;

  /// Records the fact that an invocation was made to a function with named
  /// parameters, and the named parameter associated with this node was not
  /// supplied.
  void recordNamedParameterNotSupplied(
      List<NullabilityNode> guards, NullabilityGraph graph) {
    if (isPossiblyOptional) {
      graph.connect(NullabilityNode.always, this, guards: guards);
    }
  }

  void recordNonNullIntent(
      List<NullabilityNode> guards, NullabilityGraph graph) {
    graph.connect(this, NullabilityNode.never, unconditional: true);
  }

  String toString() {
    if (_debugName == null) {
      var prefix = _debugPrefix;
      if (_debugNamesInUse.add(prefix)) {
        _debugName = prefix;
      } else {
        for (int i = 0;; i++) {
          var name = '${prefix}_$i';
          if (_debugNamesInUse.add(name)) {
            _debugName = name;
            break;
          }
        }
      }
    }
    return _debugName;
  }

  /// Tracks the possibility that this node is associated with a named parameter
  /// for which nullability migration needs to decide whether it is optional or
  /// required.
  void trackPossiblyOptional() {
    _isPossiblyOptional = true;
  }

  /// Connect the nullability nodes [sourceNode] and [destinationNode]
  /// appopriately to account for an assignment in the source code being
  /// analyzed.  Any constraints generated are recorded in [constraints].
  ///
  /// If [checkNotNull] is non-null, then it tracks the expression that may
  /// require null-checking.
  ///
  /// [inConditionalControlFlow] indicates whether the assignment being analyzed
  /// is reachable conditionally or unconditionally from the entry point of the
  /// function; this affects how non-null intent is back-propagated.
  static void recordAssignment(
      NullabilityNode sourceNode,
      NullabilityNode destinationNode,
      List<NullabilityNode> guards,
      NullabilityGraph graph,
      bool inConditionalControlFlow) {
    graph.connect(sourceNode, destinationNode,
        guards: guards, unconditional: !inConditionalControlFlow);
  }
}

/// Derived class for nullability nodes that arise from the least-upper-bound
/// implied by a conditional expression.
class NullabilityNodeForLUB extends NullabilityNodeMutable {
  final NullabilityNode left;

  final NullabilityNode right;

  NullabilityNodeForLUB._(
      Expression expression, this.left, this.right, NullabilityGraph graph)
      : super._() {
    graph.connect(left, this);
    graph.connect(right, this);
  }

  @override
  String get _debugPrefix => 'LUB($left, $right)';
}

/// Derived class for nullability nodes that arise from type variable
/// substitution.
class NullabilityNodeForSubstitution extends NullabilityNodeMutable {
  /// Nullability node representing the inner type of the substitution.
  ///
  /// For example, if this NullabilityNode arose from substituting `int*` for
  /// `T` in the type `T*`, [innerNode] is the nullability corresponding to the
  /// `*` in `int*`.
  final NullabilityNode innerNode;

  /// Nullability node representing the outer type of the substitution.
  ///
  /// For example, if this NullabilityNode arose from substituting `int*` for
  /// `T` in the type `T*`, [innerNode] is the nullability corresponding to the
  /// `*` in `T*`.
  final NullabilityNode outerNode;

  NullabilityNodeForSubstitution._(this.innerNode, this.outerNode) : super._();

  @override
  String get _debugPrefix => 'Substituted($innerNode, $outerNode)';
}

/// Base class for nullability nodes whose state can be mutated safely.
///
/// Nearly all nullability nodes derive from this class; the only exceptions are
/// the fixed nodes [NullabilityNode.always] and [NullabilityNode.never].
abstract class NullabilityNodeMutable extends NullabilityNode {
  bool _isNullable = false;

  bool _hasNonNullIntent = false;

  /// List of [_NullabilityEdge] objects describing this node's relationship to
  /// other nodes that are "downstream" from it (meaning that if a key node is
  /// nullable, then all the nodes in the corresponding value will either have
  /// to be nullable, or null checks will have to be added).
  final _downstreamEdges = <_NullabilityEdge>[];

  /// List of nodes that are "upstream" from this node via unconditional control
  /// flow (meaning that if a node in the list is nullable, then there exists
  /// code that is unguarded by an "if" statement that indicates that this node
  /// will have to be nullable, or null checks will have to be added).
  final _unconditionalUpstreamNodes = <NullabilityNode>[];

  NullabilityNodeMutable._() : super._();

  @override
  bool get hasNonNullIntent => _hasNonNullIntent;

  @override
  bool get isNullable => _isNullable;

  /// During nullability propagation, this method marks the type as nullable, or
  /// does nothing if the type was already nullable.
  ///
  /// Return value indicates whether a change was made.
  bool _becomeNullable() {
    if (_isNullable) return false;
    _isNullable = true;
    return true;
  }

  /// During nullability propagation, this method marks the type as having
  /// non-null intent, or does nothing if the type was already marked as having
  /// non-null intent.
  ///
  /// Return value indicates whether a change was made.
  bool _setNonNullIntent() {
    if (_hasNonNullIntent) return false;
    _hasNonNullIntent = true;
    return true;
  }
}

/// Data structure to keep track of the relationship from one [NullabilityNode]
/// object to another [NullabilityNode] that is "downstream" from it (meaning
/// that if the former node is nullable, then the latter node will either have
/// to be nullable, or null checks will have to be added).
class _NullabilityEdge {
  /// The node that is downstream.
  final NullabilityNode destinationNode;

  /// A set of source nodes.  By convention, the first node is the primary
  /// source and the other nodes are "guards".  The destination node will only
  /// need to be made nullable if all the source nodes are nullable.
  final List<NullabilityNode> sources;

  _NullabilityEdge(this.destinationNode, this.sources);

  Iterable<NullabilityNode> get guards => sources.skip(1);

  NullabilityNode get primarySource => sources.first;
}

class _NullabilityNodeImmutable extends NullabilityNode {
  @override
  final String _debugPrefix;

  @override
  final bool isNullable;

  _NullabilityNodeImmutable(this._debugPrefix, this.isNullable) : super._();

  @override
  bool get hasNonNullIntent => !isNullable;
}

class _NullabilityNodeSimple extends NullabilityNodeMutable {
  @override
  final String _debugPrefix;

  _NullabilityNodeSimple(this._debugPrefix) : super._();
}
