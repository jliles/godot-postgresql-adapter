#ifndef CONNECTION_POOL_H
#define CONNECTION_POOL_H

#include <pqxx/connection>

#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace godot {

// Up to `max_size` connections to one database, opened on demand and reused most-recent-first.
// acquire() gives up after a timeout instead of blocking forever, so an unreachable database
// never hangs the caller. Connections found closed are dropped and replaced on a later acquire.
// Thread-safe. Every acquired connection must be released or discarded before the pool is
// destroyed.
class ConnectionPool {
public:
	using Connection = std::unique_ptr<pqxx::connection>;

	ConnectionPool(std::string p_connection_string, int p_max_size);

	// An open connection, or nullptr with `r_error` set when none could be opened or none came
	// free within `p_timeout_ms`.
	Connection acquire(int p_timeout_ms, std::string &r_error);
	// Returns a connection for reuse (dropped instead if it has closed).
	void release(Connection p_connection);
	// Drops a connection known to be unusable.
	void discard(Connection p_connection);

private:
	Connection open(std::string &r_error) const;

	const std::string connection_string;
	const int max_size;
	int open_count = 0; // idle plus checked out
	std::vector<Connection> idle;
	std::mutex mutex;
	std::condition_variable slot_freed;
};

} // namespace godot

#endif
