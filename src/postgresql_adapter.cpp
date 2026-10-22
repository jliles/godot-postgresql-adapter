#include "postgresql_adapter.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>

#include <pqxx/except>
#include <pqxx/params>
#include <pqxx/result>

#include <string>
#include <vector>

using namespace godot;

namespace {

// PostgreSQL type OIDs mapped to native Godot types; every other type arrives as a String.
constexpr pqxx::oid OID_BOOL = 16;
constexpr pqxx::oid OID_INT8 = 20;
constexpr pqxx::oid OID_INT2 = 21;
constexpr pqxx::oid OID_INT4 = 23;
constexpr pqxx::oid OID_FLOAT4 = 700;
constexpr pqxx::oid OID_FLOAT8 = 701;

String utf8(std::string_view p_text) {
	return String::utf8(p_text.data(), static_cast<int>(p_text.size()));
}

std::string to_std(const String &p_text) {
	const CharString chars = p_text.utf8();
	return std::string(chars.get_data(), chars.length());
}

// A query converted once, ready to run (and re-run on retry).
struct Statement {
	std::string sql;
	pqxx::params params;
	bool has_params = false;
};

// Converts the query and its parameters; on an unsupported parameter type returns false with
// `r_error` set.
bool build_statement(const String &p_query, const Array &p_params, Statement &r_statement, String &r_error) {
	r_statement.sql = to_std(p_query);
	r_statement.has_params = !p_params.is_empty();
	r_statement.params.reserve(p_params.size());
	for (int64_t i = 0; i < p_params.size(); ++i) {
		const Variant &param = p_params[i];
		switch (param.get_type()) {
			case Variant::NIL:
				r_statement.params.append();
				break;
			case Variant::BOOL:
				r_statement.params.append(bool(param));
				break;
			case Variant::INT:
				r_statement.params.append(int64_t(param));
				break;
			case Variant::FLOAT:
				r_statement.params.append(double(param));
				break;
			case Variant::STRING:
			case Variant::STRING_NAME:
				r_statement.params.append(to_std(param));
				break;
			case Variant::VECTOR2: {
				const Vector2 v = param;
				r_statement.params.append("(" + pqxx::to_string(v.x) + "," + pqxx::to_string(v.y) + ")");
			} break;
			case Variant::VECTOR3: {
				const Vector3 v = param;
				r_statement.params.append("(" + pqxx::to_string(v.x) + "," + pqxx::to_string(v.y) + "," + pqxx::to_string(v.z) + ")");
			} break;
			default:
				r_error = vformat("Unsupported parameter type %s for $%d.", Variant::get_type_name(param.get_type()), i + 1);
				return false;
		}
	}
	return true;
}

// Without parameters the simple query protocol is used, so one call may run several
// semicolon-separated statements (e.g. a migration file).
pqxx::result exec(pqxx::work &p_work, const Statement &p_statement) {
	return p_statement.has_params ? p_work.exec(p_statement.sql, p_statement.params) : p_work.exec(p_statement.sql);
}

Variant field_value(const pqxx::field_ref &p_field, pqxx::oid p_type) {
	if (p_field.is_null()) {
		return Variant();
	}
	switch (p_type) {
		case OID_BOOL:
			return p_field.as<bool>();
		case OID_INT2:
		case OID_INT4:
		case OID_INT8:
			return p_field.as<int64_t>();
		case OID_FLOAT4:
		case OID_FLOAT8:
			return p_field.as<double>();
		default:
			return utf8(p_field.view());
	}
}

// Rows as Dictionaries keyed by column name. Names and types are resolved once per result,
// not per row.
Array to_rows(const pqxx::result &p_result) {
	const int columns = p_result.columns();
	std::vector<String> names;
	std::vector<pqxx::oid> types;
	names.reserve(columns);
	types.reserve(columns);
	for (int c = 0; c < columns; ++c) {
		names.push_back(utf8(p_result.column_name(c)));
		types.push_back(p_result.column_type(c));
	}
	Array rows;
	rows.resize(p_result.size());
	int64_t index = 0;
	for (const auto &row : p_result) {
		Dictionary values;
		for (int c = 0; c < columns; ++c) {
			values[names[c]] = field_value(row[c], types[c]);
		}
		rows[index++] = values;
	}
	return rows;
}

int64_t affected_rows(const pqxx::result &p_result) {
	return static_cast<int64_t>(p_result.affected_rows()); // 0 for statements without a count (DDL)
}

enum class Outcome {
	OK,
	NO_CONNECTION,
	FAILED,
};

// Runs one statement in its own transaction on a pooled connection, handing the result to
// `p_consume` before committing (so a conversion error commits nothing). A connection that
// broke while idle is replaced and the statement retried once: it can't have committed, since
// COMMIT is only sent after a successful exec. Thread-safe (the pool is).
template <typename Consume>
Outcome run_statement(ConnectionPool &p_pool, int p_timeout_ms, const Statement &p_statement, Consume &&p_consume, std::string &r_error) {
	for (int attempt = 0; attempt < 2; ++attempt) {
		ConnectionPool::Connection connection = p_pool.acquire(p_timeout_ms, r_error);
		if (!connection) {
			return Outcome::NO_CONNECTION;
		}
		try {
			pqxx::work work(*connection);
			p_consume(exec(work, p_statement));
			work.commit();
		} catch (const pqxx::broken_connection &e) {
			r_error = e.what();
			p_pool.discard(std::move(connection));
			continue;
		} catch (const std::exception &e) {
			r_error = e.what();
			p_pool.release(std::move(connection));
			return Outcome::FAILED;
		}
		p_pool.release(std::move(connection));
		return Outcome::OK;
	}
	return Outcome::FAILED;
}

} // namespace

void PostgresqlAdapter::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_connection_string", "connection_string"), &PostgresqlAdapter::set_connection_string);
	ClassDB::bind_method(D_METHOD("get_connection_string"), &PostgresqlAdapter::get_connection_string);
	ClassDB::bind_method(D_METHOD("set_pool_size", "pool_size"), &PostgresqlAdapter::set_pool_size);
	ClassDB::bind_method(D_METHOD("get_pool_size"), &PostgresqlAdapter::get_pool_size);
	ClassDB::bind_method(D_METHOD("set_acquire_timeout_ms", "timeout_ms"), &PostgresqlAdapter::set_acquire_timeout_ms);
	ClassDB::bind_method(D_METHOD("get_acquire_timeout_ms"), &PostgresqlAdapter::get_acquire_timeout_ms);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "connection_string"), "set_connection_string", "get_connection_string");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "pool_size", PROPERTY_HINT_RANGE, "1,64,1,or_greater"), "set_pool_size", "get_pool_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "acquire_timeout_ms", PROPERTY_HINT_RANGE, "0,60000,1,or_greater,suffix:ms"), "set_acquire_timeout_ms", "get_acquire_timeout_ms");

	ClassDB::bind_method(D_METHOD("get_last_error"), &PostgresqlAdapter::get_last_error);
	ClassDB::bind_method(D_METHOD("connect_to_db"), &PostgresqlAdapter::connect_to_db);
	ClassDB::bind_method(D_METHOD("disconnect_from_db"), &PostgresqlAdapter::disconnect_from_db);
	ClassDB::bind_method(D_METHOD("execute_query", "query", "params"), &PostgresqlAdapter::execute_query, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("execute_non_query", "query", "params"), &PostgresqlAdapter::execute_non_query, DEFVAL(Array()));

	ClassDB::bind_method(D_METHOD("begin_transaction"), &PostgresqlAdapter::begin_transaction);
	ClassDB::bind_method(D_METHOD("commit_transaction"), &PostgresqlAdapter::commit_transaction);
	ClassDB::bind_method(D_METHOD("rollback_transaction"), &PostgresqlAdapter::rollback_transaction);
	ClassDB::bind_method(D_METHOD("is_in_transaction"), &PostgresqlAdapter::is_in_transaction);
	ClassDB::bind_method(D_METHOD("execute_query_in_transaction", "query", "params"), &PostgresqlAdapter::execute_query_in_transaction, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("execute_non_query_in_transaction", "query", "params"), &PostgresqlAdapter::execute_non_query_in_transaction, DEFVAL(Array()));

	ClassDB::bind_method(D_METHOD("execute_query_async", "query", "params"), &PostgresqlAdapter::execute_query_async, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("execute_non_query_async", "query", "params"), &PostgresqlAdapter::execute_non_query_async, DEFVAL(Array()));

	ADD_SIGNAL(MethodInfo("connection_error", PropertyInfo(Variant::STRING, "error_message")));
	ADD_SIGNAL(MethodInfo("query_failed", PropertyInfo(Variant::STRING, "query"), PropertyInfo(Variant::STRING, "error_message")));
	ADD_SIGNAL(MethodInfo("non_query_failed", PropertyInfo(Variant::STRING, "query"), PropertyInfo(Variant::STRING, "error_message")));
	ADD_SIGNAL(MethodInfo("query_completed", PropertyInfo(Variant::INT, "request_id"), PropertyInfo(Variant::ARRAY, "results")));
	ADD_SIGNAL(MethodInfo("non_query_completed", PropertyInfo(Variant::INT, "request_id"), PropertyInfo(Variant::INT, "affected_rows")));
	ADD_SIGNAL(MethodInfo("async_query_failed", PropertyInfo(Variant::INT, "request_id"), PropertyInfo(Variant::STRING, "query"), PropertyInfo(Variant::STRING, "error_message")));
	ADD_SIGNAL(MethodInfo("transaction_started"));
	ADD_SIGNAL(MethodInfo("transaction_committed"));
	ADD_SIGNAL(MethodInfo("transaction_rolled_back"));
	ADD_SIGNAL(MethodInfo("transaction_failed", PropertyInfo(Variant::STRING, "error_message")));
}

PostgresqlAdapter::~PostgresqlAdapter() {
	// Wait for running async queries while the object is still whole (their results are
	// dropped). The members' declaration order then closes the transaction, its connection and
	// the pool.
	if (async_runner) {
		async_runner->stop(false);
	}
}

void PostgresqlAdapter::_ready() {
	if (!connection_string.is_empty()) {
		connect_to_db();
	}
}

// Settings ----------------------------------------------------------------------------------

void PostgresqlAdapter::set_connection_string(const String &p_connection_string) {
	if (p_connection_string != connection_string) {
		close_pool();
		connection_string = p_connection_string;
	}
}

String PostgresqlAdapter::get_connection_string() const {
	return connection_string;
}

void PostgresqlAdapter::set_pool_size(int p_pool_size) {
	ERR_FAIL_COND_MSG(p_pool_size < 1, "pool_size must be at least 1.");
	if (p_pool_size != pool_size) {
		close_pool();
		pool_size = p_pool_size;
	}
}

int PostgresqlAdapter::get_pool_size() const {
	return pool_size;
}

void PostgresqlAdapter::set_acquire_timeout_ms(int p_timeout_ms) {
	acquire_timeout_ms = MAX(p_timeout_ms, 0);
}

int PostgresqlAdapter::get_acquire_timeout_ms() const {
	return acquire_timeout_ms;
}

String PostgresqlAdapter::get_last_error() const {
	return last_error;
}

String PostgresqlAdapter::_to_string() const {
	// The connection string is left out: it may contain a password.
	return vformat("<PostgresqlAdapter pool_size=%d %s%s>", pool_size, pool ? "connected" : "not connected",
			transaction ? " in_transaction" : "");
}

// Connection --------------------------------------------------------------------------------

bool PostgresqlAdapter::connect_to_db() {
	last_error = String();
	// Succeeds only if a connection is (or can be) open, so callers can trust the result.
	ConnectionPool::Connection connection = acquire_connection();
	if (!connection) {
		return false;
	}
	pool->release(std::move(connection));
	return true;
}

void PostgresqlAdapter::disconnect_from_db() {
	close_pool();
}

void PostgresqlAdapter::report_connection_error(const String &p_error) {
	fail(p_error);
	emit_signal("connection_error", last_error);
}

// The pool, created on first use; nullptr (error reported) without a connection string.
std::shared_ptr<ConnectionPool> PostgresqlAdapter::get_pool() {
	if (!pool) {
		if (connection_string.is_empty()) {
			report_connection_error("No connection string set.");
			return nullptr;
		}
		pool = std::make_shared<ConnectionPool>(to_std(connection_string), pool_size);
	}
	return pool;
}

ConnectionPool::Connection PostgresqlAdapter::acquire_connection() {
	if (!get_pool()) {
		return nullptr;
	}
	std::string error;
	ConnectionPool::Connection connection = pool->acquire(acquire_timeout_ms, error);
	if (!connection) {
		report_connection_error(utf8(error));
	}
	return connection;
}

// Closes every pooled connection. Running async queries finish first (queued ones are
// cancelled), and an open transaction is rolled back, since its connection belongs to the pool.
void PostgresqlAdapter::close_pool() {
	if (async_runner) {
		async_runner->stop(true);
		async_runner.reset();
	}
	if (transaction) {
		WARN_PRINT("PostgresqlAdapter: connection settings changed or disconnected during a transaction; rolling it back.");
		rollback_transaction();
	}
	pool.reset();
}

bool PostgresqlAdapter::fail(const String &p_error) {
	last_error = p_error;
	return false;
}

// Standalone statements --------------------------------------------------------------------

template <typename Consume>
bool PostgresqlAdapter::run_standalone(const String &p_query, const Array &p_params, Consume &&p_consume) {
	last_error = String();
	Statement statement;
	if (!build_statement(p_query, p_params, statement, last_error) || !get_pool()) {
		return false;
	}
	std::string error;
	switch (run_statement(*pool, acquire_timeout_ms, statement, p_consume, error)) {
		case Outcome::OK:
			return true;
		case Outcome::NO_CONNECTION:
			report_connection_error(utf8(error));
			return false;
		default:
			return fail(utf8(error));
	}
}

Array PostgresqlAdapter::execute_query(const String &p_query, const Array &p_params) {
	Array rows;
	run_standalone(p_query, p_params, [&rows](const pqxx::result &result) { rows = to_rows(result); });
	return rows;
}

int64_t PostgresqlAdapter::execute_non_query(const String &p_query, const Array &p_params) {
	int64_t count = -1;
	const bool ok = run_standalone(p_query, p_params, [&count](const pqxx::result &result) { count = affected_rows(result); });
	return ok ? count : -1;
}

// Transactions ------------------------------------------------------------------------------

bool PostgresqlAdapter::fail_transaction(const String &p_error) {
	fail(p_error);
	emit_signal("transaction_failed", last_error);
	return false;
}

// Drops the transaction object and returns its connection to the pool.
void PostgresqlAdapter::end_transaction() {
	transaction.reset();
	pool->release(std::move(transaction_connection));
}

bool PostgresqlAdapter::begin_transaction() {
	last_error = String();
	if (transaction) {
		return fail_transaction("A transaction is already in progress.");
	}
	ConnectionPool::Connection connection = acquire_connection();
	if (!connection) {
		return fail_transaction(last_error);
	}
	try {
		transaction = std::make_unique<pqxx::work>(*connection);
	} catch (const pqxx::broken_connection &e) {
		pool->discard(std::move(connection));
		return fail_transaction(utf8(e.what()));
	} catch (const std::exception &e) {
		pool->release(std::move(connection));
		return fail_transaction(utf8(e.what()));
	}
	transaction_connection = std::move(connection);
	emit_signal("transaction_started");
	return true;
}

bool PostgresqlAdapter::commit_transaction() {
	last_error = String();
	if (!transaction) {
		return fail_transaction("No active transaction.");
	}
	try {
		transaction->commit();
	} catch (const std::exception &e) {
		end_transaction(); // a failed commit leaves nothing to roll back
		return fail_transaction(utf8(e.what()));
	}
	end_transaction();
	emit_signal("transaction_committed");
	return true;
}

bool PostgresqlAdapter::rollback_transaction() {
	last_error = String();
	if (!transaction) {
		return fail_transaction("No active transaction.");
	}
	String error;
	try {
		transaction->abort();
	} catch (const std::exception &e) {
		error = utf8(e.what());
	}
	end_transaction(); // the server discards the transaction even if the abort itself failed
	if (!error.is_empty()) {
		return fail_transaction(error);
	}
	emit_signal("transaction_rolled_back");
	return true;
}

bool PostgresqlAdapter::is_in_transaction() const {
	return transaction != nullptr;
}

// Runs one statement inside the open transaction; failures also emit `p_failed_signal`.
template <typename Consume>
bool PostgresqlAdapter::run_in_transaction(const String &p_query, const Array &p_params, const StringName &p_failed_signal, Consume &&p_consume) {
	last_error = String();
	Statement statement;
	if (!transaction) {
		fail("No active transaction.");
	} else if (build_statement(p_query, p_params, statement, last_error)) {
		try {
			p_consume(exec(*transaction, statement));
			return true;
		} catch (const std::exception &e) {
			fail(utf8(e.what()));
		}
	}
	emit_signal(p_failed_signal, p_query, last_error);
	return false;
}

Array PostgresqlAdapter::execute_query_in_transaction(const String &p_query, const Array &p_params) {
	Array rows;
	run_in_transaction(p_query, p_params, "query_failed", [&rows](const pqxx::result &result) { rows = to_rows(result); });
	return rows;
}

int64_t PostgresqlAdapter::execute_non_query_in_transaction(const String &p_query, const Array &p_params) {
	int64_t count = -1;
	const bool ok = run_in_transaction(p_query, p_params, "non_query_failed", [&count](const pqxx::result &result) { count = affected_rows(result); });
	return ok ? count : -1;
}

// Async -------------------------------------------------------------------------------------

// Queues the statement for a background thread and returns its request id at once. The result
// arrives on the main thread as `p_completed_signal(request_id, value)`, or as
// async_query_failed(request_id, query, error) (also for a bad parameter, or for a query still
// queued when the adapter disconnects). Up to pool_size queries run concurrently, each on its
// own pooled connection.
int64_t PostgresqlAdapter::run_async(const String &p_query, const Array &p_params, const StringName &p_completed_signal,
		Variant (*p_convert)(const pqxx::result &)) {
	last_error = String();
	const int64_t request_id = ++last_request_id;
	auto statement = std::make_shared<Statement>();
	if (!build_statement(p_query, p_params, *statement, last_error) || !get_pool()) {
		call_deferred("emit_signal", "async_query_failed", request_id, p_query, last_error);
		return request_id;
	}
	if (!async_runner) {
		async_runner = std::make_unique<AsyncRunner>(pool_size);
	}
	// Jobs report back only through call_deferred, which is safe from any thread. The adapter
	// outlives them: close_pool() and the destructor wait for running jobs.
	async_runner->submit([this, request_id, p_query, p_completed_signal, p_convert, statement,
								 job_pool = pool, timeout_ms = acquire_timeout_ms](bool p_cancelled) {
		if (p_cancelled) {
			call_deferred("emit_signal", "async_query_failed", request_id, p_query, "Cancelled: the adapter disconnected before the query ran.");
			return;
		}
		Variant value;
		std::string error;
		const Outcome outcome = run_statement(*job_pool, timeout_ms, *statement,
				[&value, p_convert](const pqxx::result &result) { value = p_convert(result); }, error);
		if (outcome == Outcome::OK) {
			call_deferred("emit_signal", p_completed_signal, request_id, value);
			return;
		}
		if (outcome == Outcome::NO_CONNECTION) {
			call_deferred("emit_signal", "connection_error", utf8(error));
		}
		call_deferred("emit_signal", "async_query_failed", request_id, p_query, utf8(error));
	});
	return request_id;
}

int64_t PostgresqlAdapter::execute_query_async(const String &p_query, const Array &p_params) {
	return run_async(p_query, p_params, "query_completed", [](const pqxx::result &result) -> Variant { return to_rows(result); });
}

int64_t PostgresqlAdapter::execute_non_query_async(const String &p_query, const Array &p_params) {
	return run_async(p_query, p_params, "non_query_completed", [](const pqxx::result &result) -> Variant { return affected_rows(result); });
}
