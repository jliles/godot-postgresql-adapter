#ifndef ASYNC_RUNNER_H
#define ASYNC_RUNNER_H

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace godot {

// Runs jobs on up to `thread_count` background threads, started with the first job. Jobs
// start in submission order but run concurrently, so they may finish in any order.
class AsyncRunner {
public:
	// Called on a background thread with `p_cancelled` false, or by stop() with it true for a job
	// that never started.
	using Job = std::function<void(bool p_cancelled)>;

	explicit AsyncRunner(int p_thread_count);
	// Waits for running jobs; queued jobs are dropped without being called.
	~AsyncRunner();

	void submit(Job p_job);
	// Waits for running jobs to finish and stops the threads. Queued jobs are called with
	// `p_cancelled` true (on the calling thread) if `p_notify_queued`, otherwise dropped.
	void stop(bool p_notify_queued);

private:
	void work();

	const int thread_count;
	std::deque<Job> queue;
	std::vector<std::thread> threads;
	std::mutex mutex;
	std::condition_variable has_work;
	bool stopping = false;
};

} // namespace godot

#endif
