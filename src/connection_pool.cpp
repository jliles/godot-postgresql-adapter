#include "connection_pool.h"

#include <algorithm>
#include <chrono>

namespace godot {

ConnectionPool::ConnectionPool(std::string p_connection_string, int p_max_size) :
		connection_string(std::move(p_connection_string)),
		max_size(std::max(p_max_size, 1)) {
}

ConnectionPool::Connection ConnectionPool::open(std::string &r_error) const {
	try {
		return std::make_unique<pqxx::connection>(connection_string);
	} catch (const std::exception &e) {
		r_error = e.what();
		return nullptr;
	}
}

ConnectionPool::Connection ConnectionPool::acquire(int p_timeout_ms, std::string &r_error) {
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(std::max(p_timeout_ms, 0));
	std::unique_lock<std::mutex> lock(mutex);
	while (true) {
		while (!idle.empty()) {
			Connection connection = std::move(idle.back());
			idle.pop_back();
			if (connection->is_open()) {
				return connection;
			}
			open_count--; // closed while idle (e.g. the server restarted): drop it
		}
		if (open_count < max_size) {
			open_count++; // reserve the slot, then connect without holding the lock
			lock.unlock();
			Connection connection = open(r_error);
			if (connection) {
				return connection;
			}
			lock.lock();
			open_count--;
			slot_freed.notify_one();
			return nullptr;
		}
		const bool freed = slot_freed.wait_until(lock, deadline, [this] {
			return !idle.empty() || open_count < max_size;
		});
		if (!freed) {
			r_error = "Timed out waiting for a free database connection.";
			return nullptr;
		}
	}
}

void ConnectionPool::release(Connection p_connection) {
	if (!p_connection) {
		return;
	}
	if (!p_connection->is_open()) {
		discard(std::move(p_connection));
		return;
	}
	std::lock_guard<std::mutex> lock(mutex);
	idle.push_back(std::move(p_connection));
	slot_freed.notify_one();
}

void ConnectionPool::discard(Connection p_connection) {
	if (!p_connection) {
		return;
	}
	p_connection.reset(); // close outside the lock
	std::lock_guard<std::mutex> lock(mutex);
	open_count--;
	slot_freed.notify_one();
}

} // namespace godot
