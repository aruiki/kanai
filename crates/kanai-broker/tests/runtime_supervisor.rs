use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use kanai_broker::{
    MAX_STOP_CONFIRM_TIMEOUT, RuntimeChild, RuntimeClock, RuntimeFailure, RuntimeProcess,
    RuntimeProcessError, RuntimeStateSnapshot, RuntimeSupervisor, RuntimeSupervisorConfig,
    RuntimeSupervisorConfigError, RuntimeSupervisorError, RuntimeSupervisorState,
};
use tokio::sync::Notify;
use tokio::time::timeout;

/// Local alias so the config-bound test reads clearly.
fn validate(config: RuntimeSupervisorConfig) -> Result<(), RuntimeSupervisorConfigError> {
    config.validate()
}

struct ManualClock {
    sleeps: Mutex<Vec<Duration>>,
    wake: Notify,
}

impl ManualClock {
    fn new() -> Self {
        Self {
            sleeps: Mutex::new(Vec::new()),
            wake: Notify::new(),
        }
    }

    fn sleep_count(&self) -> usize {
        self.sleeps.lock().expect("clock lock").len()
    }

    fn sleeps(&self) -> Vec<Duration> {
        self.sleeps.lock().expect("clock lock").clone()
    }

    fn advance(&self) {
        self.wake.notify_one();
    }
}

#[async_trait]
impl RuntimeClock for ManualClock {
    async fn sleep(&self, duration: Duration) {
        self.sleeps.lock().expect("clock lock").push(duration);
        self.wake.notified().await;
    }
}

struct FakeChild {
    exit_requested: AtomicBool,
    exit_signal: Notify,
    graceful_stops: AtomicUsize,
    forced_stops: AtomicUsize,
    wait_calls: AtomicUsize,
    force_error: AtomicBool,
    graceful_exit: AtomicBool,
}

impl FakeChild {
    fn new() -> Self {
        Self {
            exit_requested: AtomicBool::new(false),
            exit_signal: Notify::new(),
            graceful_stops: AtomicUsize::new(0),
            forced_stops: AtomicUsize::new(0),
            wait_calls: AtomicUsize::new(0),
            force_error: AtomicBool::new(false),
            graceful_exit: AtomicBool::new(true),
        }
    }

    fn exit(&self) {
        self.exit_requested.store(true, Ordering::Release);
        // There is at most one wait future for a child.  notify_one also
        // leaves a permit when the monitor has not started waiting yet.
        self.exit_signal.notify_one();
    }

    fn graceful_stops(&self) -> usize {
        self.graceful_stops.load(Ordering::Acquire)
    }

    fn forced_stops(&self) -> usize {
        self.forced_stops.load(Ordering::Acquire)
    }

    fn wait_calls(&self) -> usize {
        self.wait_calls.load(Ordering::Acquire)
    }

    fn block_graceful_stop(&self) {
        self.graceful_exit.store(false, Ordering::Release);
    }

    fn fail_force_stop(&self) {
        self.force_error.store(true, Ordering::Release);
    }
}

#[async_trait]
impl RuntimeChild for FakeChild {
    async fn wait(&self) -> Result<(), RuntimeProcessError> {
        self.wait_calls.fetch_add(1, Ordering::AcqRel);
        loop {
            if self.exit_requested.swap(false, Ordering::AcqRel) {
                return Ok(());
            }
            self.exit_signal.notified().await;
        }
    }

    async fn graceful_stop(&self) -> Result<(), RuntimeProcessError> {
        self.graceful_stops.fetch_add(1, Ordering::AcqRel);
        if self.graceful_exit.load(Ordering::Acquire) {
            self.exit();
        }
        Ok(())
    }

    async fn force_stop(&self) -> Result<(), RuntimeProcessError> {
        self.forced_stops.fetch_add(1, Ordering::AcqRel);
        self.exit();
        if self.force_error.load(Ordering::Acquire) {
            Err(RuntimeProcessError::Rejected)
        } else {
            Ok(())
        }
    }
}

struct FakeProcess {
    child: Arc<FakeChild>,
    starts: AtomicUsize,
    next_start_error: Mutex<Option<RuntimeProcessError>>,
}

impl FakeProcess {
    fn new() -> Self {
        Self {
            child: Arc::new(FakeChild::new()),
            starts: AtomicUsize::new(0),
            next_start_error: Mutex::new(None),
        }
    }

    fn starts(&self) -> usize {
        self.starts.load(Ordering::Acquire)
    }

    fn fail_next_start(&self, error: RuntimeProcessError) {
        *self.next_start_error.lock().expect("process lock") = Some(error);
    }
}

#[async_trait]
impl RuntimeProcess for FakeProcess {
    async fn start(&self) -> Result<Arc<dyn RuntimeChild>, RuntimeProcessError> {
        if let Some(error) = self.next_start_error.lock().expect("process lock").take() {
            return Err(error);
        }
        self.starts.fetch_add(1, Ordering::AcqRel);
        Ok(Arc::clone(&self.child) as Arc<dyn RuntimeChild>)
    }
}

struct GatedProcess {
    child: Arc<FakeChild>,
    starts: AtomicUsize,
    block_from: usize,
    release: Notify,
}

impl GatedProcess {
    fn new(block_from: usize) -> Self {
        Self {
            child: Arc::new(FakeChild::new()),
            starts: AtomicUsize::new(0),
            block_from,
            release: Notify::new(),
        }
    }

    fn starts(&self) -> usize {
        self.starts.load(Ordering::Acquire)
    }

    fn release_start(&self) {
        self.release.notify_one();
    }
}

#[async_trait]
impl RuntimeProcess for GatedProcess {
    async fn start(&self) -> Result<Arc<dyn RuntimeChild>, RuntimeProcessError> {
        let call = self.starts.fetch_add(1, Ordering::AcqRel);
        if call >= self.block_from {
            self.release.notified().await;
        }
        Ok(Arc::clone(&self.child) as Arc<dyn RuntimeChild>)
    }
}

fn config(max_restarts: u32) -> RuntimeSupervisorConfig {
    RuntimeSupervisorConfig {
        max_restarts,
        initial_backoff: Duration::from_millis(10),
        max_backoff: Duration::from_millis(15),
        // Tests assert on stop behaviour directly, so the bound is kept far
        // below the production default to keep the suite fast while still
        // exercising the same code path.
        stop_confirm_timeout: Duration::from_millis(500),
    }
}

async fn yield_until(mut predicate: impl FnMut() -> bool) {
    timeout(Duration::from_secs(1), async {
        loop {
            if predicate() {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("condition should become true");
}

fn make_supervisor<P>(
    process: Arc<P>,
    clock: Arc<ManualClock>,
    max_restarts: u32,
) -> Arc<RuntimeSupervisor>
where
    P: RuntimeProcess,
{
    RuntimeSupervisor::new(process, clock, config(max_restarts)).expect("valid supervisor config")
}

#[test]
fn supervisor_config_rejects_unbounded_restart_or_backoff_values() {
    let unbounded_restarts = RuntimeSupervisorConfig {
        max_restarts: kanai_broker::MAX_RUNTIME_RESTARTS + 1,
        initial_backoff: Duration::from_millis(1),
        max_backoff: Duration::from_millis(1),
        ..config(1)
    };
    assert!(unbounded_restarts.validate().is_err());

    let unbounded_backoff = RuntimeSupervisorConfig {
        max_restarts: 1,
        initial_backoff: Duration::from_secs(61),
        max_backoff: Duration::from_secs(61),
        ..config(1)
    };
    assert!(unbounded_backoff.validate().is_err());
}

#[tokio::test(flavor = "current_thread")]
async fn duplicate_start_does_not_create_a_second_child() {
    let process = Arc::new(FakeProcess::new());
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);

    supervisor.start().await.expect("initial start");
    assert_eq!(
        supervisor.start().await,
        Err(RuntimeSupervisorError::AlreadyRunning)
    );
    assert_eq!(process.starts(), 1);

    supervisor.stop_gracefully().await.expect("graceful stop");
    assert_eq!(process.child.graceful_stops(), 1);
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Idle);
}

#[tokio::test(flavor = "current_thread")]
async fn unexpected_exit_restarts_up_to_the_configured_limit() {
    let process = Arc::new(FakeProcess::new());
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);

    supervisor.start().await.expect("initial start");
    process.child.exit();
    yield_until(|| clock.sleep_count() == 1).await;
    assert_eq!(
        supervisor.snapshot().state,
        RuntimeSupervisorState::BackingOff
    );
    clock.advance();
    yield_until(|| process.starts() == 2).await;
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Running);

    process.child.exit();
    yield_until(|| clock.sleep_count() == 2).await;
    clock.advance();
    yield_until(|| process.starts() == 3).await;
    let snapshot = supervisor.snapshot();
    assert_eq!(snapshot.state, RuntimeSupervisorState::Running);
    assert_eq!(snapshot.automatic_restarts, 2);
    assert_eq!(
        clock.sleeps(),
        vec![Duration::from_millis(10), Duration::from_millis(15)]
    );

    supervisor.stop_gracefully().await.expect("final stop");
}

#[tokio::test(flavor = "current_thread")]
async fn restart_limit_is_terminal_and_typed_in_the_snapshot() {
    let process = Arc::new(FakeProcess::new());
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 1);

    supervisor.start().await.expect("initial start");
    process.child.exit();
    yield_until(|| clock.sleep_count() == 1).await;
    clock.advance();
    yield_until(|| process.starts() == 2).await;
    process.child.exit();
    yield_until(|| supervisor.snapshot().state == RuntimeSupervisorState::Failed).await;

    let snapshot = supervisor.snapshot();
    assert_eq!(snapshot.state, RuntimeSupervisorState::Failed);
    assert_eq!(snapshot.automatic_restarts, 1);
    assert!(matches!(
        snapshot.last_error,
        Some(RuntimeFailure::RestartLimitExceeded { limit: 1, .. })
    ));
    assert_eq!(process.starts(), 2);
    assert!(matches!(
        supervisor.start().await,
        Err(RuntimeSupervisorError::InvalidState {
            state: RuntimeSupervisorState::Failed
        })
    ));
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Failed);
}

#[tokio::test(flavor = "current_thread")]
async fn cancellation_during_backoff_does_not_start_a_replacement() {
    let process = Arc::new(FakeProcess::new());
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 3);

    supervisor.start().await.expect("initial start");
    process.child.exit();
    yield_until(|| clock.sleep_count() == 1).await;
    assert_eq!(
        supervisor.snapshot().state,
        RuntimeSupervisorState::BackingOff
    );

    supervisor.cancel().await.expect("cancel backoff");
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Idle);
    clock.advance();
    for _ in 0..8 {
        tokio::task::yield_now().await;
    }
    assert_eq!(process.starts(), 1);
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Idle);
}

#[tokio::test(flavor = "current_thread")]
async fn force_stop_during_blocked_initial_start_is_terminal_and_cleans_late_child() {
    let process = Arc::new(GatedProcess::new(0));
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);

    let start_task = tokio::spawn({
        let supervisor = Arc::clone(&supervisor);
        async move { supervisor.start().await }
    });
    yield_until(|| process.starts() == 1).await;
    assert_eq!(
        supervisor.snapshot().state,
        RuntimeSupervisorState::Starting
    );

    let stop_result = timeout(Duration::from_secs(1), supervisor.force_stop())
        .await
        .expect("force stop must not wait for the factory");
    assert_eq!(stop_result, Ok(()));
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Failed);
    assert!(matches!(
        supervisor.snapshot().last_error,
        Some(RuntimeFailure::StartCancelled)
    ));

    let start_result = timeout(Duration::from_secs(1), start_task)
        .await
        .expect("start waiter must be released")
        .expect("start task join");
    assert_eq!(start_result, Err(RuntimeSupervisorError::StartCancelled));

    process.release_start();
    yield_until(|| process.child.forced_stops() == 1).await;
    assert_eq!(process.starts(), 1);
    assert_eq!(process.child.wait_calls(), 0);
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Failed);
}

#[tokio::test(flavor = "current_thread")]
async fn dropping_a_blocked_start_waiter_marks_the_start_cancelled() {
    let process = Arc::new(GatedProcess::new(0));
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);

    let start_task = tokio::spawn({
        let supervisor = Arc::clone(&supervisor);
        async move { supervisor.start().await }
    });
    yield_until(|| process.starts() == 1).await;
    start_task.abort();
    let _ = start_task.await;
    yield_until(|| supervisor.snapshot().state == RuntimeSupervisorState::Failed).await;
    assert!(matches!(
        supervisor.snapshot().last_error,
        Some(RuntimeFailure::StartCancelled)
    ));

    process.release_start();
    yield_until(|| process.child.forced_stops() == 1).await;
    assert_eq!(process.child.wait_calls(), 0);
}

#[tokio::test(flavor = "current_thread")]
async fn blocked_restart_start_is_stopped_without_attaching_a_replacement() {
    let process = Arc::new(GatedProcess::new(1));
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);

    supervisor.start().await.expect("initial start");
    process.child.exit();
    yield_until(|| clock.sleep_count() == 1).await;
    clock.advance();
    yield_until(|| {
        process.starts() == 2 && supervisor.snapshot().state == RuntimeSupervisorState::Starting
    })
    .await;

    let stop_result = timeout(Duration::from_secs(1), supervisor.force_stop())
        .await
        .expect("force stop must not wait for the replacement factory");
    assert_eq!(stop_result, Ok(()));
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Failed);
    assert!(matches!(
        supervisor.snapshot().last_error,
        Some(RuntimeFailure::StartCancelled)
    ));

    process.release_start();
    yield_until(|| process.child.forced_stops() == 1).await;
    assert_eq!(process.starts(), 2);
    assert_eq!(process.child.wait_calls(), 1);
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Failed);
}

#[tokio::test(flavor = "current_thread")]
async fn stop_is_idempotent_and_uses_one_stop_request() {
    let process = Arc::new(FakeProcess::new());
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);

    supervisor.start().await.expect("initial start");
    supervisor.stop_gracefully().await.expect("first stop");
    supervisor.stop_gracefully().await.expect("second stop");
    supervisor.force_stop().await.expect("stop after idle");

    assert_eq!(process.child.graceful_stops(), 1);
    assert_eq!(process.child.forced_stops(), 0);
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Idle);
}

#[tokio::test(flavor = "current_thread")]
async fn forced_stop_upgrades_an_unfinished_graceful_stop() {
    let process = Arc::new(FakeProcess::new());
    process.child.block_graceful_stop();
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);

    supervisor.start().await.expect("initial start");
    let graceful = tokio::spawn({
        let supervisor = Arc::clone(&supervisor);
        async move { supervisor.stop_gracefully().await }
    });
    yield_until(|| process.child.graceful_stops() == 1).await;
    assert_eq!(
        supervisor.snapshot().state,
        RuntimeSupervisorState::Stopping
    );

    supervisor.force_stop().await.expect("forced stop");
    graceful
        .await
        .expect("graceful task")
        .expect("graceful result");
    supervisor
        .force_stop()
        .await
        .expect("idempotent forced stop");

    assert_eq!(process.child.forced_stops(), 1);
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Idle);
}

/// A child whose `wait` panics, standing in for an adapter that can fail in an
/// unrecoverable way. Tokio's process `Child` has panic paths on Windows, and
/// `tokio::spawn` swallows a task panic, so the monitor task can disappear
/// while the supervisor still believes a child is running.
struct PanickingWaitChild {
    observed: AtomicBool,
}

#[async_trait]
impl RuntimeChild for PanickingWaitChild {
    async fn wait(&self) -> Result<(), RuntimeProcessError> {
        self.observed.store(true, Ordering::Release);
        panic!("the adapter cannot observe this child");
    }

    async fn graceful_stop(&self) -> Result<(), RuntimeProcessError> {
        Ok(())
    }

    async fn force_stop(&self) -> Result<(), RuntimeProcessError> {
        Ok(())
    }
}

struct PanickingWaitProcess {
    child: Arc<PanickingWaitChild>,
}

#[async_trait]
impl RuntimeProcess for PanickingWaitProcess {
    async fn start(&self) -> Result<Arc<dyn RuntimeChild>, RuntimeProcessError> {
        Ok(Arc::clone(&self.child) as Arc<dyn RuntimeChild>)
    }
}

/// A stop must never block forever.
///
/// The `watch` sender lives in the supervisor, so `wait_for_stop` cannot detect
/// a closed channel while the supervisor is alive. If the monitor task dies
/// after attaching the child, nothing publishes `Idle` or `Failed` again, and
/// without the bound the stop would wait on a state transition that can never
/// arrive.
#[tokio::test(flavor = "current_thread")]
async fn a_stop_after_the_monitor_task_dies_returns_instead_of_hanging() {
    let child = Arc::new(PanickingWaitChild {
        observed: AtomicBool::new(false),
    });
    let clock = Arc::new(ManualClock::new());
    let process = Arc::new(PanickingWaitProcess {
        child: Arc::clone(&child),
    });
    let supervisor = RuntimeSupervisor::new(
        process,
        Arc::clone(&clock) as Arc<dyn RuntimeClock>,
        RuntimeSupervisorConfig {
            max_restarts: 0,
            initial_backoff: Duration::from_millis(10),
            max_backoff: Duration::from_millis(15),
            stop_confirm_timeout: Duration::from_millis(100),
        },
    )
    .expect("supervisor config");

    supervisor.start().await.expect("initial start");
    yield_until(|| child.observed.load(Ordering::Acquire)).await;
    // Let the panicked monitor task unwind and be dropped by the runtime.
    for _ in 0..8 {
        tokio::task::yield_now().await;
    }
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Running);

    let result = timeout(Duration::from_secs(30), supervisor.force_stop())
        .await
        .expect("force stop must return even when the monitor task is gone");
    assert_eq!(
        result,
        Err(RuntimeSupervisorError::Unavailable),
        "a stop that cannot be observed must be reported, not waited on forever"
    );
}

#[test]
fn the_stop_confirmation_bound_cannot_be_disabled_or_unbounded() {
    let base = config(1);
    for stop_confirm_timeout in [
        Duration::ZERO,
        MAX_STOP_CONFIRM_TIMEOUT + Duration::from_secs(1),
    ] {
        let rejected = RuntimeSupervisorConfig {
            stop_confirm_timeout,
            ..base
        };
        assert_eq!(
            validate(rejected),
            Err(RuntimeSupervisorConfigError::InvalidStopConfirmTimeout)
        );
    }
    assert_eq!(validate(base), Ok(()));
    assert_eq!(
        validate(RuntimeSupervisorConfig {
            stop_confirm_timeout: MAX_STOP_CONFIRM_TIMEOUT,
            ..base
        }),
        Ok(())
    );
}

#[tokio::test(flavor = "current_thread")]
async fn force_stop_error_becomes_a_terminal_typed_failure() {
    let process = Arc::new(FakeProcess::new());
    process.child.fail_force_stop();
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);

    supervisor.start().await.expect("initial start");
    let result = timeout(Duration::from_secs(1), supervisor.force_stop())
        .await
        .expect("force stop must return on adapter error");
    assert_eq!(
        result,
        Err(RuntimeSupervisorError::StopFailed {
            source: RuntimeProcessError::Rejected,
        })
    );
    let snapshot = supervisor.snapshot();
    assert_eq!(snapshot.state, RuntimeSupervisorState::Failed);
    assert_eq!(
        snapshot.last_error,
        Some(RuntimeFailure::Stop {
            source: RuntimeProcessError::Rejected,
        })
    );
    for _ in 0..8 {
        tokio::task::yield_now().await;
    }
    assert_eq!(process.starts(), 1);
    assert_eq!(supervisor.snapshot().state, RuntimeSupervisorState::Failed);
}

#[tokio::test(flavor = "current_thread")]
async fn start_error_is_reflected_in_a_typed_state_snapshot() {
    let process = Arc::new(FakeProcess::new());
    process.fail_next_start(RuntimeProcessError::Unavailable);
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);

    assert!(matches!(
        supervisor.start().await,
        Err(RuntimeSupervisorError::StartFailed {
            source: RuntimeProcessError::Unavailable
        })
    ));
    let snapshot: RuntimeStateSnapshot = supervisor.snapshot();
    assert_eq!(snapshot.state, RuntimeSupervisorState::Failed);
    assert_eq!(
        snapshot.last_error,
        Some(RuntimeFailure::Start {
            source: RuntimeProcessError::Unavailable
        })
    );
    assert_eq!(process.starts(), 0);
}

/// Releasing a supervisor is what forbids the restart it was about to make.
///
/// This is the mechanism the AI composition relies on when it releases the
/// supervisor *before* it removes the key file: a replacement child started
/// against a key file that no longer exists is a loopback model server with no
/// authentication, so the sequence has to end with "nothing more can be
/// started", not with "the removal happened, probably first".
#[tokio::test(flavor = "current_thread")]
async fn a_released_supervisor_never_starts_a_replacement() {
    // The control. With the supervisor alive, a pending backoff becomes a
    // replacement; without this, the assertion below would also hold against a
    // supervisor that simply never restarts anything.
    let control_process = Arc::new(FakeProcess::new());
    let control_clock = Arc::new(ManualClock::new());
    let control = make_supervisor(Arc::clone(&control_process), Arc::clone(&control_clock), 2);
    control.start().await.expect("initial start");
    control_process.child.exit();
    yield_until(|| control_clock.sleep_count() == 1).await;
    control_clock.advance();
    yield_until(|| control_process.starts() == 2).await;
    control.force_stop().await.expect("stop the control");

    // The same sequence, with the supervisor released while the replacement is
    // still pending.
    let process = Arc::new(FakeProcess::new());
    let clock = Arc::new(ManualClock::new());
    let supervisor = make_supervisor(Arc::clone(&process), Arc::clone(&clock), 2);
    supervisor.start().await.expect("initial start");
    process.child.exit();
    yield_until(|| clock.sleep_count() == 1).await;
    drop(supervisor);
    clock.advance();
    // A released supervisor publishes its shutdown, which ends the backoff
    // without a replacement. Give the monitor the turns it would need to start
    // one anyway.
    for _ in 0..8 {
        tokio::task::yield_now().await;
    }
    assert_eq!(
        process.starts(),
        1,
        "a released supervisor must not start a replacement"
    );
}
