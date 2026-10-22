extends SceneTree
## Tests for PostgresqlAdapter against a real, throwaway PostgreSQL database. Run with
## tests/run_tests.sh, which checks PG_TEST_URL first. Exits with the number of failed checks.

var url := OS.get_environment("PG_TEST_URL")
var failures := 0
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for method in get_method_list():
		var name: String = method["name"]
		if name.begins_with("test_"):
			var before := failures
			await call(name)
			_report(name, before)
	print("test_adapter.gd: %d checks, %d failed" % [checks, failures])
	quit(mini(failures, 125))


func _report(name: String, before: int) -> void:
	print(("ok   " if failures == before else "FAIL ") + name)


func check(condition: bool, what: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		print("  FAIL ", what)


func expect_eq(actual: Variant, expected: Variant, what: String) -> void:
	checks += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		failures += 1
		print("  FAIL %s: expected %s, got %s" % [what, var_to_str(expected), var_to_str(actual)])


func adapter(pool_size := 2) -> PostgresqlAdapter:
	var db := PostgresqlAdapter.new()
	db.pool_size = pool_size
	db.acquire_timeout_ms = 500
	db.connection_string = url
	return db


func fresh_table(db: PostgresqlAdapter) -> void:
	db.execute_non_query("DROP TABLE IF EXISTS adapter_test")
	db.execute_non_query("CREATE TABLE adapter_test (id serial PRIMARY KEY, name text)")


# Connecting -----------------------------------------------------------------------------------

func test_unreachable_database_fails_fast_with_error() -> void:
	var db := PostgresqlAdapter.new()
	db.connection_string = "postgresql://nobody@127.0.0.1:1/none?connect_timeout=2"
	var errors: Array[String] = []
	db.connection_error.connect(func(e: String) -> void: errors.append(e))
	var started := Time.get_ticks_msec()
	check(not db.connect_to_db(), "connect fails")
	check(Time.get_ticks_msec() - started < 3000, "fails within the connect timeout")
	check(db.get_last_error() != "", "error is reported")
	expect_eq(errors.size(), 1, "connection_error emitted once")
	expect_eq(db.execute_query("SELECT 1"), [], "query without a database returns []")
	expect_eq(db.execute_non_query("SELECT 1"), -1, "non-query without a database returns -1")
	db.free()


func test_missing_connection_string() -> void:
	var db := PostgresqlAdapter.new()
	check(not db.connect_to_db(), "connect fails")
	check(db.get_last_error().contains("connection string"), "error names the problem")
	db.free()


func test_tls_connection() -> void:
	var db := adapter(1)
	db.connection_string = url + ("&" if url.contains("?") else "?") + "sslmode=require"
	var rows := db.execute_query("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
	var error := db.get_last_error()
	check(not error.contains("not compiled in"), "built with TLS support: " + error)
	if error.contains("does not support SSL"):
		print("  (test server has TLS off; only checked that sslmode=require is accepted)")
	else:
		expect_eq(rows, [{"ssl": true}], "connection is encrypted")
	db.free()


func test_connect_and_last_error_cleared_by_success() -> void:
	var db := adapter()
	check(db.connect_to_db(), "connects")
	db.execute_query("SELECT * FROM no_such_table")
	check(db.get_last_error().contains("no_such_table"), "SQL error reported")
	expect_eq(db.execute_query("SELECT 1 AS one"), [{"one": 1}], "adapter still works after an SQL error")
	expect_eq(db.get_last_error(), "", "success clears the error")
	db.free()


func test_to_string_hides_the_password() -> void:
	var db := PostgresqlAdapter.new()
	db.connection_string = "postgresql://user:hunter2@127.0.0.1/db"
	check(not str(db).contains("hunter2"), "password not printed: " + str(db))
	db.free()


# Types --------------------------------------------------------------------------------------

func test_result_types() -> void:
	var db := adapter()
	var rows := db.execute_query("SELECT true AS b, 2::int2 AS s, 40000::int4 AS i, 9007199254740993::int8 AS l, " +
		"1.5::float4 AS f, 2.25::float8 AS d, 1.10::numeric AS n, NULL::int AS z, 'x'::text AS t")
	expect_eq(rows.size(), 1, "one row")
	var row: Dictionary = rows[0]
	expect_eq(row["b"], true, "bool")
	expect_eq(row["s"], 2, "int2")
	expect_eq(row["i"], 40000, "int4")
	expect_eq(row["l"], 9007199254740993, "int8 keeps 64-bit precision")
	expect_eq(row["f"], 1.5, "float4")
	expect_eq(row["d"], 2.25, "float8")
	expect_eq(row["n"], "1.10", "numeric arrives as text")
	expect_eq(row["z"], null, "NULL")
	expect_eq(row["t"], "x", "text")
	db.free()


func test_utf8_round_trip() -> void:
	var db := adapter()
	var text := "Zoë ✓ 日本 🐉"
	var rows := db.execute_query("SELECT $1::text AS \"naïve\", length($1::text) AS n", [text])
	expect_eq(rows[0].get("naïve"), text, "text and column name decode as UTF-8")
	expect_eq(rows[0]["n"], text.length(), "server saw the same characters")
	db.free()


func test_parameter_types() -> void:
	var db := adapter()
	var rows := db.execute_query("SELECT $1::bool AS b, $2::int8 AS i, $3::float8 AS f, $4::text AS s, " +
		"$5::text AS sn, $6::point AS p, $7::text AS v3, $8::int AS z",
		[false, -(1 << 62), 0.125, "it's", &"name", Vector2(1.5, -2), Vector3(1, 2, 3), null])
	var row: Dictionary = rows[0] if rows.size() == 1 else {}
	expect_eq(row.get("b"), false, "bool")
	expect_eq(row.get("i"), -(1 << 62), "int")
	expect_eq(row.get("f"), 0.125, "float")
	expect_eq(row.get("s"), "it's", "string (not spliced into SQL)")
	expect_eq(row.get("sn"), "name", "StringName")
	expect_eq(row.get("p"), "(1.5,-2)", "Vector2 as point")
	expect_eq(row.get("v3"), "(1,2,3)", "Vector3 as text")
	expect_eq(row.get("z"), null, "null")
	db.free()


func test_unsupported_parameter_is_an_error() -> void:
	var db := adapter()
	expect_eq(db.execute_query("SELECT $1::text AS x", [{"a": 1}]), [], "query fails")
	check(db.get_last_error().contains("Dictionary") and db.get_last_error().contains("$1"), "error names type and position: " + db.get_last_error())
	expect_eq(db.execute_non_query("SELECT $1::text", [Color.RED]), -1, "non-query fails")
	db.free()


# Statements ---------------------------------------------------------------------------------

func test_non_query_counts() -> void:
	var db := adapter()
	expect_eq(db.execute_non_query("DROP TABLE IF EXISTS adapter_test"), 0, "DDL counts 0")
	expect_eq(db.execute_non_query("CREATE TABLE adapter_test (id serial PRIMARY KEY, name text)"), 0, "CREATE counts 0")
	expect_eq(db.execute_non_query("INSERT INTO adapter_test (name) VALUES ('a'), ('b'), ('c')"), 3, "INSERT count")
	expect_eq(db.execute_non_query("UPDATE adapter_test SET name = 'z' WHERE name <> $1", ["a"]), 2, "UPDATE count")
	expect_eq(db.execute_non_query("INSERT INTO adapter_test (id) VALUES (1)"), -1, "constraint violation returns -1")
	check(db.get_last_error().contains("duplicate key"), "violation reported")
	db.free()


func test_multiple_statements_without_parameters() -> void:
	var db := adapter()
	fresh_table(db)
	check(db.execute_non_query("INSERT INTO adapter_test (name) VALUES ('a'); INSERT INTO adapter_test (name) VALUES ('b')") >= 0, "runs")
	expect_eq(db.execute_query("SELECT count(*) AS n FROM adapter_test")[0]["n"], 2, "both statements ran")
	db.free()


func test_many_rows() -> void:
	var db := adapter()
	var started := Time.get_ticks_usec()
	var rows := db.execute_query("SELECT g AS id, 'name ' || g AS name, g % 2 = 0 AS even FROM generate_series(1, 50000) g")
	var elapsed_ms := (Time.get_ticks_usec() - started) / 1000.0
	expect_eq(rows.size(), 50000, "all rows")
	expect_eq(rows[49999], {"id": 50000, "name": "name 50000", "even": true}, "last row intact")
	print("  50000 rows x 3 columns in %.1f ms" % elapsed_ms)
	db.free()


# Transactions -------------------------------------------------------------------------------

func test_commit_and_rollback() -> void:
	var db := adapter()
	fresh_table(db)
	var events: Array[String] = []
	db.transaction_started.connect(func() -> void: events.append("started"))
	db.transaction_committed.connect(func() -> void: events.append("committed"))
	db.transaction_rolled_back.connect(func() -> void: events.append("rolled_back"))

	check(db.begin_transaction(), "begin")
	check(db.is_in_transaction(), "in transaction")
	expect_eq(db.execute_non_query_in_transaction("INSERT INTO adapter_test (name) VALUES ($1)", ["kept"]), 1, "insert in transaction")
	expect_eq(db.execute_query_in_transaction("SELECT name FROM adapter_test"), [{"name": "kept"}], "visible inside")
	check(db.commit_transaction(), "commit")
	check(not db.is_in_transaction(), "transaction ended")

	check(db.begin_transaction(), "begin again")
	db.execute_non_query_in_transaction("INSERT INTO adapter_test (name) VALUES ('dropped')")
	check(db.rollback_transaction(), "rollback")
	expect_eq(db.execute_query("SELECT name FROM adapter_test"), [{"name": "kept"}], "only the committed row exists")
	expect_eq(events, ["started", "committed", "started", "rolled_back"] as Array[String], "signals")
	db.free()


func test_transaction_misuse_fails_cleanly() -> void:
	var db := adapter()
	var failed: Array[String] = []
	db.transaction_failed.connect(func(e: String) -> void: failed.append(e))
	check(not db.commit_transaction(), "commit without transaction fails")
	check(not db.rollback_transaction(), "rollback without transaction fails")
	var query_errors: Array[String] = []
	db.query_failed.connect(func(_q: String, e: String) -> void: query_errors.append(e))
	expect_eq(db.execute_query_in_transaction("SELECT 1"), [], "query outside a transaction fails")
	expect_eq(query_errors.size(), 1, "query_failed emitted")
	check(db.begin_transaction(), "begin")
	check(not db.begin_transaction(), "nested begin fails")
	check(db.is_in_transaction(), "first transaction still open")
	check(db.rollback_transaction(), "rollback")
	expect_eq(failed.size(), 3, "transaction_failed for each misuse")
	db.free()


func test_error_inside_transaction() -> void:
	var db := adapter()
	fresh_table(db)
	var errors: Array[String] = []
	db.non_query_failed.connect(func(_q: String, e: String) -> void: errors.append(e))
	db.begin_transaction()
	db.execute_non_query_in_transaction("INSERT INTO adapter_test (name) VALUES ('lost')")
	expect_eq(db.execute_non_query_in_transaction("INSERT INTO nowhere VALUES (1)"), -1, "failing statement returns -1")
	expect_eq(errors.size(), 1, "non_query_failed emitted")
	expect_eq(db.execute_non_query_in_transaction("SELECT $1::text", [Callable()]), -1, "bad parameter fails")
	expect_eq(errors.size(), 2, "non_query_failed for the bad parameter")
	check(db.rollback_transaction(), "rollback after errors")
	expect_eq(db.execute_query("SELECT count(*) AS n FROM adapter_test")[0]["n"], 0, "nothing committed")
	db.free()


func test_changing_settings_during_transaction_rolls_back() -> void:
	var db := adapter()
	fresh_table(db)
	db.begin_transaction()
	db.execute_non_query_in_transaction("INSERT INTO adapter_test (name) VALUES ('x')")
	db.pool_size = 3
	check(not db.is_in_transaction(), "transaction ended")
	expect_eq(db.execute_query("SELECT count(*) AS n FROM adapter_test")[0]["n"], 0, "rolled back, and the adapter works")
	db.begin_transaction()
	db.disconnect_from_db()
	check(not db.is_in_transaction(), "disconnect ends the transaction")
	db.free()


## Backend connections currently open under `app`, as seen from a separate adapter.
func sessions_named(app: String) -> int:
	var observer := adapter(1)
	var rows := observer.execute_query("SELECT count(*) AS n FROM pg_stat_activity WHERE application_name = $1", [app])
	observer.free()
	return rows[0]["n"] if rows.size() == 1 else -1


func with_app_name(app: String) -> String:
	return url + ("&" if url.contains("?") else "?") + "application_name=" + app


func test_free_during_transaction_closes_connections() -> void:
	var db := adapter(2)
	db.connection_string = with_app_name("free_in_tx")
	db.execute_query_async("SELECT 1")
	db.begin_transaction()
	check(sessions_named("free_in_tx") >= 1, "connection open while in the transaction")
	db.free()
	var deadline := Time.get_ticks_msec() + 2000
	while sessions_named("free_in_tx") != 0 and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	expect_eq(sessions_named("free_in_tx"), 0, "freeing closed every connection")


# Pool ---------------------------------------------------------------------------------------

func test_recovers_from_killed_connection() -> void:
	var db := adapter(1)
	var pid: int = db.execute_query("SELECT pg_backend_pid() AS pid")[0]["pid"]
	var killer := adapter(1)
	killer.execute_query("SELECT pg_terminate_backend($1)", [pid])
	var rows := db.execute_query("SELECT pg_backend_pid() AS pid")
	check(rows.size() == 1 and rows[0]["pid"] != pid, "query retried on a fresh connection")
	expect_eq(db.get_last_error(), "", "no error after recovery")
	killer.free()
	db.free()


func test_exhausted_pool_times_out() -> void:
	var db := adapter(1)
	db.begin_transaction() # holds the only connection
	var started := Time.get_ticks_msec()
	expect_eq(db.execute_query("SELECT 1"), [], "query fails")
	var waited := Time.get_ticks_msec() - started
	check(waited >= 450 and waited < 2000, "waited about acquire_timeout_ms (%d ms)" % waited)
	check(db.get_last_error().contains("Timed out"), "timeout reported")
	db.rollback_transaction()
	expect_eq(db.execute_query("SELECT 1 AS one"), [{"one": 1}], "usable once the connection is back")
	db.free()


func test_pool_reuses_connections() -> void:
	var db := adapter(4)
	var pids := {}
	for i in 20:
		pids[db.execute_query("SELECT pg_backend_pid() AS pid")[0]["pid"]] = true
	expect_eq(pids.size(), 1, "sequential queries reuse one connection")
	db.free()


# Async --------------------------------------------------------------------------------------

## Collects async results by request id.
class AsyncLog:
	var done := {}    # request_id -> result
	var failed := {}  # request_id -> error

	func _init(db: PostgresqlAdapter) -> void:
		db.query_completed.connect(func(id: int, rows: Array) -> void: done[id] = rows)
		db.non_query_completed.connect(func(id: int, count: int) -> void: done[id] = count)
		db.async_query_failed.connect(func(id: int, _q: String, e: String) -> void: failed[id] = e)

	func count() -> int:
		return done.size() + failed.size()


func wait_for(log: AsyncLog, expected: int, seconds := 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while log.count() < expected and Time.get_ticks_msec() < deadline:
		await process_frame
	return log.count() >= expected


func test_async_results_and_errors() -> void:
	var db := adapter()
	var log := AsyncLog.new(db)
	var rows_id := db.execute_query_async("SELECT $1::int AS n", [7])
	var count_id := db.execute_non_query_async("SELECT 1")
	var bad_sql_id := db.execute_query_async("SELECT * FROM no_such_table")
	var bad_param_id := db.execute_query_async("SELECT $1", [Callable()])
	check(rows_id != count_id and count_id != bad_sql_id, "distinct request ids")
	check(await wait_for(log, 4), "all four reported")
	expect_eq(log.done.get(rows_id), [{"n": 7}], "rows")
	expect_eq(log.done.get(count_id), 1, "affected count")
	check(str(log.failed.get(bad_sql_id, "")).contains("no_such_table"), "SQL error reported")
	check(str(log.failed.get(bad_param_id, "")).contains("Callable"), "bad parameter reported")
	db.free()


func test_async_does_not_block_and_runs_concurrently() -> void:
	var db := adapter(4)
	var log := AsyncLog.new(db)
	var started := Time.get_ticks_msec()
	for i in 4:
		db.execute_query_async("SELECT pg_sleep(0.4), $1::int AS i", [i])
	var submit_ms := Time.get_ticks_msec() - started
	check(submit_ms < 100, "submitting returns at once (%d ms)" % submit_ms)
	check(await wait_for(log, 4), "all finished")
	var total_ms := Time.get_ticks_msec() - started
	check(total_ms < 1200, "four 0.4 s queries ran concurrently (%d ms)" % total_ms)
	expect_eq(log.failed.size(), 0, "no failures")
	db.free()


func test_async_beyond_pool_size_queues() -> void:
	var db := adapter(2)
	db.acquire_timeout_ms = 5000
	var log := AsyncLog.new(db)
	for i in 6:
		db.execute_query_async("SELECT pg_sleep(0.1)")
	check(await wait_for(log, 6), "all six finished")
	expect_eq(log.failed.size(), 0, "queued queries waited for a connection instead of failing")
	db.free()


func test_sync_and_async_share_the_adapter() -> void:
	var db := adapter(2)
	var log := AsyncLog.new(db)
	db.execute_query_async("SELECT pg_sleep(0.2)")
	expect_eq(db.execute_query("SELECT 5 AS n"), [{"n": 5}], "sync query works while async runs")
	check(await wait_for(log, 1), "async finished")
	db.free()


func test_disconnect_cancels_queued_async() -> void:
	var db := adapter(1)
	var log := AsyncLog.new(db)
	var running := db.execute_query_async("SELECT pg_sleep(0.3) AS slept")
	var queued := db.execute_query_async("SELECT 1")
	await create_timer(0.1).timeout
	db.disconnect_from_db() # waits for the running query, cancels the queued one
	check(await wait_for(log, 2), "both reported")
	check(log.done.has(running), "running query completed")
	check(str(log.failed.get(queued, "")).contains("Cancelled"), "queued query cancelled")
	expect_eq(db.execute_query("SELECT 2 AS n"), [{"n": 2}], "adapter reconnects afterwards")
	db.free()


func test_free_with_async_in_flight() -> void:
	var db := adapter(2)
	var log := AsyncLog.new(db)
	db.execute_query_async("SELECT pg_sleep(0.3)")
	db.execute_query_async("SELECT pg_sleep(0.3)")
	db.execute_query_async("SELECT 1")
	await create_timer(0.1).timeout # let the first two start
	var started := Time.get_ticks_msec()
	db.free()
	var waited := Time.get_ticks_msec() - started
	check(waited >= 100, "free waited for the running queries (%d ms)" % waited)
	await process_frame
	expect_eq(log.count(), 0, "no results delivered to the freed adapter")
