#include "async_runner.h"

#include <algorithm>

namespace godot {

AsyncRunner::AsyncRunner(int p_thread_count) :
		thread_count(std::max(p_thread_count, 1)) {
}

AsyncRunner::~AsyncRunner() {
	stop(false);
}

void AsyncRunner::submit(Job p_job) {
	std::lock_guard<std::mutex> lock(mutex);
	if (stopping) {
		return;
	}
	queue.push_back(std::move(p_job));
	if (threads.empty()) {
		threads.reserve(thread_count);
		for (int i = 0; i < thread_count; ++i) {
			threads.emplace_back(&AsyncRunner::work, this);
		}
	}
	has_work.notify_one();
}

void AsyncRunner::stop(bool p_notify_queued) {
	std::deque<Job> unstarted;
	{
		std::lock_guard<std::mutex> lock(mutex);
		stopping = true;
		unstarted.swap(queue);
	}
	has_work.notify_all();
	for (std::thread &thread : threads) {
		thread.join();
	}
	threads.clear();
	if (p_notify_queued) {
		for (Job &job : unstarted) {
			job(true);
		}
	}
}

void AsyncRunner::work() {
	while (true) {
		Job job;
		{
			std::unique_lock<std::mutex> lock(mutex);
			has_work.wait(lock, [this] { return stopping || !queue.empty(); });
			if (stopping) {
				return;
			}
			job = std::move(queue.front());
			queue.pop_front();
		}
		job(false);
	}
}

} // namespace godot
