## Runs work on WorkerThreadPool and hands each result to its callback on the main thread from
## poll(). Work must not touch the scene tree or create GPU resources such as textures (Godot
## manual, "Thread-safe APIs"); the callback does that.
extends RefCounted

## Background jobs running at once, so a burst of cover decodes leaves workers free for the
## selection's own jobs.
const MAX_BACKGROUND: int = 3


class Job:
	extends RefCounted
	var work: Callable
	var done: Callable
	var background: bool = false
	var task_id: int = -1
	var result: Variant = null

	func run() -> void:
		result = work.call()


var _queued: Array[Job] = []
var _running: Array[Job] = []
var _background_running: int = 0


## Calls `work` (no arguments) on a worker, then `done(result)` on the main thread. Foreground
## jobs start at once at high priority; background ones wait for a free slot, oldest first.
func add(work: Callable, done: Callable, background: bool = false) -> void:
	var job := Job.new()
	job.work = work
	job.done = done
	job.background = background
	if background:
		_queued.append(job)
		_start_queued()
	else:
		_start(job)


func poll() -> void:
	var i := 0
	while i < _running.size():
		var job := _running[i]
		if not WorkerThreadPool.is_task_completed(job.task_id):
			i += 1
			continue
		# Every task must be waited for once, which also frees it (WorkerThreadPool docs).
		WorkerThreadPool.wait_for_task_completion(job.task_id)
		_running.remove_at(i)
		if job.background:
			_background_running -= 1
		if job.done.is_valid():
			job.done.call(job.result)
	_start_queued()


func is_idle() -> bool:
	return _running.is_empty() and _queued.is_empty()


## Drops queued work and blocks until running work ends, without calling back; for teardown.
func cancel() -> void:
	_queued.clear()
	for job in _running:
		WorkerThreadPool.wait_for_task_completion(job.task_id)
	_running.clear()
	_background_running = 0


func _start(job: Job) -> void:
	job.task_id = WorkerThreadPool.add_task(job.run, not job.background, "Kenbu menu")
	_running.append(job)
	if job.background:
		_background_running += 1


func _start_queued() -> void:
	while not _queued.is_empty() and _background_running < MAX_BACKGROUND:
		_start(_queued.pop_front())
