#ifndef POSTGRESQL_ADAPTER_H
#define POSTGRESQL_ADAPTER_H

#include "async_runner.h"
#include "connection_pool.h"

#include <godot_cpp/classes/node.hpp>
#include <pqxx/transaction>

#include <memory>

namespace godot {

// PostgreSQL access for Godot: parameterized queries over a connection pool, explicit
// transactions, asynchronous queries on background threads, and non-fatal error reporting
// (failures return []/-1 and set get_last_error()). Call it from one thread; the *_async
// methods do their own threading.
class PostgresqlAdapter : public Node {
	GDCLASS(PostgresqlAdapter, Node)

public:
	~PostgresqlAdapter() override;

	void _ready() override;

	void set_connection_string(const String &p_connection_string);
	String get_connection_string() const;
	void set_pool_size(int p_pool_size);
	int get_pool_size() const;
	void set_acquire_timeout_ms(int p_timeout_ms);
	int get_acquire_timeout_ms() const;
	String get_last_error() const;

	bool connect_to_db();
	void disconnect_from_db();

	Array execute_query(const String &p_query, const Array &p_params = Array());
	int64_t execute_non_query(const String &p_query, const Array &p_params = Array());

	bool begin_transaction();
	bool commit_transaction();
	bool rollback_transaction();
	bool is_in_transaction() const;
	Array execute_query_in_transaction(const String &p_query, const Array &p_params = Array());
	int64_t execute_non_query_in_transaction(const String &p_query, const Array &p_params = Array());

	int64_t execute_query_async(const String &p_query, const Array &p_params = Array());
	int64_t execute_non_query_async(const String &p_query, const Array &p_params = Array());

	String _to_string() const;

protected:
	static void _bind_methods();

private:
	template <typename Consume>
	bool run_standalone(const String &p_query, const Array &p_params, Consume &&p_consume);
	template <typename Consume>
	bool run_in_transaction(const String &p_query, const Array &p_params, const StringName &p_failed_signal, Consume &&p_consume);
	int64_t run_async(const String &p_query, const Array &p_params, const StringName &p_completed_signal,
			Variant (*p_convert)(const pqxx::result &));

	std::shared_ptr<ConnectionPool> get_pool();
	void report_connection_error(const String &p_error);
	ConnectionPool::Connection acquire_connection();
	void close_pool();
	void end_transaction();
	bool fail(const String &p_error);
	bool fail_transaction(const String &p_error);

	String connection_string;
	int pool_size = 4;
	// How long to wait for a free (or newly opened) connection before failing.
	int acquire_timeout_ms = 5000;
	// Message of the most recent failure; every call clears it first.
	String last_error;
	int64_t last_request_id = 0;

	// Declaration order matters (members are destroyed in reverse): the async threads stop
	// first, then the transaction closes, then its connection, then the pool. Async jobs hold
	// their own reference to the pool they started with.
	std::shared_ptr<ConnectionPool> pool;
	ConnectionPool::Connection transaction_connection;
	std::unique_ptr<pqxx::work> transaction;
	std::unique_ptr<AsyncRunner> async_runner;
};

} // namespace godot

#endif
