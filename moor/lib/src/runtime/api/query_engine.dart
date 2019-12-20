part of 'runtime_api.dart';

const _zoneRootUserKey = #DatabaseConnectionUser;

typedef _CustomWriter<T> = Future<T> Function(
    QueryExecutor e, String sql, List<dynamic> vars);

/// Mixin for a [DatabaseConnectionUser]. Provides an API to execute both
/// high-level and custom queries and fetch their results.
mixin QueryEngine on DatabaseConnectionUser {
  /// Whether this connection user is "top level", e.g. there is no parent
  /// connection user. We consider a [GeneratedDatabase] and a
  /// [DatabaseAccessor] to be top-level, while a [Transaction] or a
  /// [BeforeOpenRunner] aren't.
  ///
  /// If any query method is called on a [topLevel] database user, we check if
  /// it could instead be delegated to a child executor. For instance, consider
  /// this code, assuming its part of a subclass of [GeneratedDatabase]:
  /// ```dart
  /// void example() {
  ///  transaction((t) async {
  ///   await update(table).write(/*...*/)
  ///  });
  /// }
  /// ```
  /// Here, the `update` method would be called on the [GeneratedDatabase]
  /// although it is very likely that the user meant to call it on the
  /// [Transaction] t. We can detect this by calling the function passed to
  /// `transaction` in a forked [Zone] storing the transaction in
  @protected
  bool get topLevel => false;

  /// We can detect when a user called methods on the wrong [QueryEngine]
  /// (e.g. calling [QueryEngine.into] in a transaction, where
  /// [QueryEngine.into] should have been called instead). See the documentation
  /// of [topLevel] on how this works.
  QueryEngine get _resolvedEngine {
    if (!topLevel) {
      // called directly in a transaction / other child callback, so use this
      // instance directly
      return this;
    } else {
      // if an overridden executor has been specified for this zone (this will
      // happen for transactions), use that one.
      final resolved = Zone.current[_zoneRootUserKey];
      return (resolved as QueryEngine) ?? this;
    }
  }

  /// Starts an [InsertStatement] for a given table. You can use that statement
  /// to write data into the [table] by using [InsertStatement.insert].
  @protected
  @visibleForTesting
  InsertStatement<T> into<T extends DataClass>(TableInfo<Table, T> table) =>
      InsertStatement<T>(_resolvedEngine, table);

  /// Starts an [UpdateStatement] for the given table. You can use that
  /// statement to update individual rows in that table by setting a where
  /// clause on that table and then use [UpdateStatement.write].
  @protected
  @visibleForTesting
  UpdateStatement<Tbl, R> update<Tbl extends Table, R extends DataClass>(
          TableInfo<Tbl, R> table) =>
      UpdateStatement(_resolvedEngine, table);

  /// Starts a query on the given table.
  ///
  /// In moor, queries are commonly used as a builder by chaining calls on them
  /// using the `..` syntax from Dart. For instance, to load the 10 oldest users
  /// with an 'S' in their name, you could use:
  /// ```dart
  /// Future<List<User>> oldestUsers() {
  ///   return (
  ///     select(users)
  ///       ..where((u) => u.name.like('%S%'))
  ///       ..orderBy([(u) => OrderingTerm(
  ///         expression: u.id,
  ///         mode: OrderingMode.asc
  ///       )])
  ///       ..limit(10)
  ///   ).get();
  /// }
  /// ```
  ///
  /// The [distinct] parameter (defaults to false) can be used to remove
  /// duplicate rows from the result set.
  ///
  /// For more information on queries, see the
  /// [documentation](https://moor.simonbinder.eu/docs/getting-started/writing_queries/).
  @protected
  @visibleForTesting
  SimpleSelectStatement<T, R> select<T extends Table, R extends DataClass>(
      TableInfo<T, R> table,
      {bool distinct = false}) {
    return SimpleSelectStatement<T, R>(_resolvedEngine, table,
        distinct: distinct);
  }

  /// Starts a [DeleteStatement] that can be used to delete rows from a table.
  ///
  /// See the [documentation](https://moor.simonbinder.eu/docs/getting-started/writing_queries/#updates-and-deletes)
  /// for more details and example on how delete statements work.
  @protected
  @visibleForTesting
  DeleteStatement<T, D> delete<T extends Table, D extends DataClass>(
      TableInfo<T, D> table) {
    return DeleteStatement<T, D>(_resolvedEngine, table);
  }

  /// Executes a custom delete or update statement and returns the amount of
  /// rows that have been changed.
  /// You can use the [updates] parameter so that moor knows which tables are
  /// affected by your query. All select streams that depend on a table
  /// specified there will then issue another query.
  @protected
  @visibleForTesting
  Future<int> customUpdate(String query,
      {List<Variable> variables = const [], Set<TableInfo> updates}) async {
    return _customWrite(query, variables, updates, (executor, sql, vars) {
      return executor.runUpdate(sql, vars);
    });
  }

  /// Executes a custom insert statement and returns the last inserted rowid.
  ///
  /// You can tell moor which tables your query is going to affect by using the
  /// [updates] parameter. Query-streams running on any of these tables will
  /// then be re-run.
  @protected
  @visibleForTesting
  Future<int> customInsert(String query,
      {List<Variable> variables = const [], Set<TableInfo> updates}) {
    return _customWrite(query, variables, updates, (executor, sql, vars) {
      return executor.runInsert(sql, vars);
    });
  }

  /// Common logic for [customUpdate] and [customInsert] which takes care of
  /// mapping the variables, running the query and optionally informing the
  /// stream-queries.
  Future<T> _customWrite<T>(String query, List<Variable> variables,
      Set<TableInfo> updates, _CustomWriter<T> writer) async {
    final engine = _resolvedEngine;
    final executor = engine.executor;

    final ctx = GenerationContext.fromDb(engine);
    final mappedArgs = variables.map((v) => v.mapToSimpleValue(ctx)).toList();

    final result =
        await executor.doWhenOpened((e) => writer(e, query, mappedArgs));

    if (updates != null) {
      await engine.streamQueries.handleTableUpdates(updates);
    }

    return result;
  }

  /// Executes a custom select statement once. To use the variables, mark them
  /// with a "?" in your [query]. They will then be changed to the appropriate
  /// value.
  @protected
  @visibleForTesting
  @Deprecated('use customSelectQuery(...).get() instead')
  Future<List<QueryRow>> customSelect(String query,
      {List<Variable> variables = const []}) async {
    return customSelectQuery(query, variables: variables).get();
  }

  /// Creates a stream from a custom select statement.To use the variables, mark
  /// them with a "?" in your [query]. They will then be changed to the
  /// appropriate value. The stream will re-emit items when any table in
  /// [readsFrom] changes, so be sure to set it to the set of tables your query
  /// reads data from.
  @protected
  @visibleForTesting
  @Deprecated('use customSelectQuery(...).watch() instead')
  Stream<List<QueryRow>> customSelectStream(String query,
      {List<Variable> variables = const [], Set<TableInfo> readsFrom}) {
    return customSelectQuery(query, variables: variables, readsFrom: readsFrom)
        .watch();
  }

  /// Creates a custom select statement from the given sql [query]. To run the
  /// query once, use [Selectable.get]. For an auto-updating streams, set the
  /// set of tables the ready [readsFrom] and use [Selectable.watch]. If you
  /// know the query will never emit more than one row, you can also use
  /// [Selectable.getSingle] and [Selectable.watchSingle] which return the item
  /// directly or wrapping it into a list.
  ///
  /// If you use variables in your query (for instance with "?"), they will be
  /// bound to the [variables] you specify on this query.
  @protected
  @visibleForTesting
  Selectable<QueryRow> customSelectQuery(String query,
      {List<Variable> variables = const [],
      Set<TableInfo> readsFrom = const {}}) {
    readsFrom ??= {};
    return CustomSelectStatement(query, variables, readsFrom, _resolvedEngine);
  }

  /// Executes the custom sql [statement] on the database.
  @protected
  @visibleForTesting
  Future<void> customStatement(String statement, [List<dynamic> args]) {
    final engine = _resolvedEngine;

    return engine.executor.doWhenOpened((executor) {
      return executor.runCustom(statement, args);
    });
  }

  /// Executes [action] in a transaction, which means that all its queries and
  /// updates will be called atomically.
  ///
  /// Please be aware of the following limitations of transactions:
  ///  1. Inside a transaction, auto-updating streams cannot be created. This
  ///     operation will throw at runtime. The reason behind this is that a
  ///     stream might have a longer lifespan than a transaction, but it still
  ///     needs to know about the transaction because the data in a transaction
  ///     might be different than that of the "global" database instance.
  ///  2. Nested transactions are not supported. Creating another transaction
  ///     inside a transaction returns the parent transaction.
  Future<T> transaction<T>(Future<T> Function() action) async {
    final resolved = _resolvedEngine;
    if (resolved is Transaction) {
      return action();
    }

    final executor = resolved.executor;
    return await executor.doWhenOpened((executor) {
      final transactionExecutor = executor.beginTransaction();
      final transaction = Transaction(this, transactionExecutor);

      return _runEngineZoned(transaction, () async {
        var success = false;
        try {
          final result = await action();
          success = true;
          return result;
        } catch (e) {
          await transactionExecutor.rollback();

          // pass the exception on to the one who called transaction()
          rethrow;
        } finally {
          if (success) {
            // calling complete will also take care of committing the transaction
            await transaction.complete();
          }
        }
      });
    });
  }

  /// Runs statements inside a batch.
  ///
  /// A batch can only run a subset of statements, and those statements must be
  /// called on the [Batch] instance. The statements aren't executed with a call
  /// to [Batch]. Instead, all generated queries are queued up and are then run
  /// and executed atomically.
  /// Typically, running bulk updates (so a lot of similar statements) over a
  /// [Batch] is much faster than running them via the [GeneratedDatabase]
  /// directly.
  ///
  /// An example that inserts users in a batch:
  /// ```dart
  ///  await batch((b) {
  ///    b.insertAll(
  ///      todos,
  ///      [
  ///        TodosCompanion.insert(content: 'Use batches'),
  ///        TodosCompanion.insert(content: 'Have fun'),
  ///      ],
  ///    );
  ///  });
  /// ```
  @protected
  @visibleForTesting
  Future<void> batch(Function(Batch) runInBatch) {
    final resolved = _resolvedEngine;
    if (resolved is Transaction) {
      // we use runBatched in the implementation, which is always run as top
      // level with sqflite.
      throw UnsupportedError('Batches cannot be used inside a transaction');
    }

    final batch = Batch._(resolved);
    runInBatch(batch);
    return batch._commit();
  }

  /// Runs [calculation] in a forked [Zone] that has its [_resolvedEngine] set
  /// to the [engine].
  ///
  /// For details, see the documentation at [topLevel].
  @protected
  Future<T> _runEngineZoned<T>(
      QueryEngine engine, Future<T> Function() calculation) {
    return runZoned(calculation, zoneValues: {_zoneRootUserKey: engine});
  }

  /// Will be used by generated code to resolve inline Dart expressions in sql.
  @protected
  GenerationContext $write(Component component, {bool hasMultipleTables: null}) {
    final context = GenerationContext.fromDb(this);
    if (hasMultipleTables != null) {
      context.hasMultipleTables = hasMultipleTables;
    }

    // we don't want ORDER BY clauses to write the ORDER BY tokens because those
    // are already declared in sql
    if (component is OrderBy) {
      component.writeInto(context, writeOrderBy: false);
    } else {
      component.writeInto(context);
    }

    return context;
  }
}
