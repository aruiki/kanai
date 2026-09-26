//! A bounded, pre-integration lifecycle boundary for an eventual local AI
//! runtime process.
//!
//! This module is intentionally independent from the broker composition root.
//! It does not launch a real process and it does not change the broker's Mozc
//! fallback path.  A platform adapter can provide a [`RuntimeProcess`] and a
//! [`RuntimeClock`] later, while tests can provide deterministic fakes.
//!
//! One supervisor owns at most one live child.  Unexpected child exits are
//! retried a bounded number of times with capped exponential backoff.  Process
//! factory futures run without the lifecycle mutex; a non-cooperative factory
//! is isolated by a generation guard, and a child returned after cancellation
//! is force-stopped instead of being attached.  A failed supervisor stays
//! failed until a new supervisor is created; callers must not interpret this
//! module as proof that an AI runtime is bundled or supervised by the product.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use thiserror::Error;
use tokio::runtime::Handle;
use tokio::sync::{Mutex, Notify, oneshot, watch};

/// Hard upper bound for automatic restart attempts in one supervisor.
pub const MAX_RUNTIME_RESTARTS: u32 = 16;
/// Hard upper bound for any configured backoff delay.
pub const MAX_RUNTIME_BACKOFF: Duration = Duration::from_secs(60);
/// Hard upper bound for the stop-confirmation wait.
pub const MAX_STOP_CONFIRM_TIMEOUT: Duration = Duration::from_secs(300);

const STOP_NONE: u8 = 0;
const STOP_GRACEFUL: u8 = 1;
const STOP_FORCE: u8 = 2;

/// Upper bound on how long a stop request waits for the monitor task to publish
/// a terminal state.
///
/// The wait is a *bookkeeping* wait, not the stop itself.  By the time a caller
/// reaches it the stop has already been delivered to the adapter, and an
/// adapter that owns a kill-on-close job has already asked the operating system
/// to terminate the child.  The bound therefore only limits how long the caller
/// blocks on a state transition that a dead monitor task can no longer make.
///
/// Without a bound the wait cannot end: the `watch` sender lives in [`Shared`],
/// which the supervisor owns, so [`watch::Receiver::changed`] cannot report a
/// closed channel while the supervisor is alive.  If the monitor task died
/// between attaching the child and stopping it, nothing would ever publish
/// `Idle` or `Failed`, and `stop_gracefully`, `force_stop` and `cancel` would
/// all hang forever.
const STOP_CONFIRM_TIMEOUT: Duration = Duration::from_secs(30);

/// Configuration validation failures for [`RuntimeSupervisor`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum RuntimeSupervisorConfigError {
    #[error("automatic restart limit is outside 0..={MAX_RUNTIME_RESTARTS}")]
    InvalidRestartLimit,
    #[error("backoff must be non-decreasing and at most 60 seconds")]
    InvalidBackoff,
    #[error("stop confirmation timeout must be nonzero and at most 300 seconds")]
    InvalidStopConfirmTimeout,
}

/// Errors reported by an injected process adapter.
///
/// The fixed variants intentionally carry no command output.  Adapters must
/// map arbitrary process diagnostics to one of these typed values before
/// returning them to the supervisor.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum RuntimeProcessError {
    #[error("runtime process is unavailable")]
    Unavailable,
    #[error("runtime process rejected a lifecycle request")]
    Rejected,
    #[error("runtime process wait operation failed")]
    WaitFailed,
}

/// An injected process factory.
///
/// `start` must return a new, owned child handle.  It is invoked without the
/// supervisor lifecycle mutex held.  Implementations should make cancellation
/// of a start attempt safe: if the returned future is dropped, the
/// implementation must not leave an unowned live child behind.  A
/// non-cooperative future may finish after cancellation; the supervisor then
/// force-stops that late child using its generation guard.
#[async_trait]
pub trait RuntimeProcess: Send + Sync + 'static {
    async fn start(&self) -> Result<Arc<dyn RuntimeChild>, RuntimeProcessError>;
}

/// A child handle owned by one [`RuntimeSupervisor`].
///
/// `wait` is called once at a time.  It should be cancellation-safe because
/// the supervisor may arrange for a forced stop while that future is pending.
/// Stop methods should be idempotent at the adapter boundary; a graceful stop
/// future may be canceled when a force request upgrades it.
#[async_trait]
pub trait RuntimeChild: Send + Sync + 'static {
    /// Verify the server half of an already connected TCP socket belongs to
    /// this live child. Call before sending secrets, and use that same socket.
    /// Adapters without OS ownership evidence fail closed.
    fn verify_connection(&self, _local: std::net::SocketAddr, _peer: std::net::SocketAddr) -> bool {
        false
    }
    /// Wait for the child to exit.  It must not return while the child is
    /// still live, otherwise a replacement could overlap it.
    async fn wait(&self) -> Result<(), RuntimeProcessError>;

    /// Request a graceful stop and return once the request has been issued.
    async fn graceful_stop(&self) -> Result<(), RuntimeProcessError>;

    /// Request an immediate/forced stop and return once the request has been
    /// issued.
    async fn force_stop(&self) -> Result<(), RuntimeProcessError>;
}

/// An injected clock used only for lifecycle backoff.
///
/// Keeping this boundary small makes cancellation during backoff testable
/// without sleeping in real time or starting a process.  `sleep` must be
/// cancellation-safe because shutdown drops the pending delay.
#[async_trait]
pub trait RuntimeClock: Send + Sync + 'static {
    async fn sleep(&self, duration: Duration);
}

/// The normal Tokio implementation of [`RuntimeClock`].
///
/// This is a pre-integration helper only; it does not imply that a process
/// adapter is installed in the broker.
#[derive(Debug, Clone, Copy, Default)]
pub struct TokioRuntimeClock;

#[async_trait]
impl RuntimeClock for TokioRuntimeClock {
    async fn sleep(&self, duration: Duration) {
        tokio::time::sleep(duration).await;
    }
}

/// The externally visible lifecycle state of a supervisor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeSupervisorState {
    /// No child is live and no automatic restart is pending.
    Idle,
    /// An injected process factory is being started; no child is attached yet.
    Starting,
    /// Exactly one child handle is owned by the supervisor.
    Running,
    /// The child exited unexpectedly and an automatic restart is waiting for
    /// the injected backoff clock.
    BackingOff,
    /// A graceful or forced stop has been requested for the current child.
    Stopping,
    /// The supervisor reached a terminal error and will not start another
    /// child.
    Failed,
}

impl std::fmt::Display for RuntimeSupervisorState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let name = match self {
            Self::Idle => "idle",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::BackingOff => "backing-off",
            Self::Stopping => "stopping",
            Self::Failed => "failed",
        };
        formatter.write_str(name)
    }
}

/// A typed failure retained in [`RuntimeStateSnapshot`].
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum RuntimeFailure {
    #[error("runtime start failed: {source}")]
    Start { source: RuntimeProcessError },
    #[error("runtime exited unexpectedly")]
    UnexpectedExit { cause: Option<RuntimeProcessError> },
    #[error("runtime start was cancelled before a child was attached")]
    StartCancelled,
    #[error("automatic restart failed")]
    Restart { cause: Option<RuntimeProcessError> },
    #[error("automatic restart limit reached after {limit} attempts")]
    RestartLimitExceeded {
        limit: u32,
        cause: Option<RuntimeProcessError>,
    },
    #[error("runtime stop failed: {source}")]
    Stop { source: RuntimeProcessError },
}

/// A consistent, typed snapshot of supervisor state.
///
/// The snapshot contains lifecycle metadata only.  It never contains prompts,
/// candidate text, tokens, command lines, or arbitrary process output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeStateSnapshot {
    pub state: RuntimeSupervisorState,
    pub automatic_restarts: u32,
    pub last_error: Option<RuntimeFailure>,
}

/// Bounded restart, backoff, and stop-confirmation policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeSupervisorConfig {
    /// Number of automatic replacements allowed after the initial child.
    pub max_restarts: u32,
    /// Delay before the first automatic replacement.
    pub initial_backoff: Duration,
    /// Upper bound for each exponential delay.
    pub max_backoff: Duration,
    /// Upper bound on how long a stop request waits for the monitor task to
    /// publish a terminal state. Must be nonzero and at most
    /// [`MAX_STOP_CONFIRM_TIMEOUT`].
    ///
    /// This bounds a *bookkeeping* wait, not the stop itself: by the time it
    /// applies the stop has already been delivered to the adapter. See
    /// [`STOP_CONFIRM_TIMEOUT`] for why an unbounded wait cannot be correct.
    pub stop_confirm_timeout: Duration,
}

impl Default for RuntimeSupervisorConfig {
    fn default() -> Self {
        Self {
            max_restarts: 3,
            initial_backoff: Duration::from_millis(100),
            max_backoff: Duration::from_secs(2),
            stop_confirm_timeout: STOP_CONFIRM_TIMEOUT,
        }
    }
}

impl RuntimeSupervisorConfig {
    /// Validate hard resource bounds before a supervisor is created.
    pub fn validate(self) -> Result<(), RuntimeSupervisorConfigError> {
        if self.max_restarts > MAX_RUNTIME_RESTARTS {
            return Err(RuntimeSupervisorConfigError::InvalidRestartLimit);
        }
        if self.initial_backoff > MAX_RUNTIME_BACKOFF
            || self.max_backoff > MAX_RUNTIME_BACKOFF
            || self.initial_backoff > self.max_backoff
        {
            return Err(RuntimeSupervisorConfigError::InvalidBackoff);
        }
        // A zero value would report a stop as unconfirmed before the adapter
        // could act on it, and an unbounded value would reintroduce the
        // indefinite wait this bound exists to prevent.
        if self.stop_confirm_timeout.is_zero()
            || self.stop_confirm_timeout > MAX_STOP_CONFIRM_TIMEOUT
        {
            return Err(RuntimeSupervisorConfigError::InvalidStopConfirmTimeout);
        }
        Ok(())
    }

    fn delay_for(self, restart_attempt: u32) -> Duration {
        if self.initial_backoff.is_zero() || self.max_backoff.is_zero() {
            return Duration::ZERO;
        }
        let exponent = restart_attempt.saturating_sub(1).min(31);
        let multiplier = 1_u32 << exponent;
        self.initial_backoff
            .saturating_mul(multiplier)
            .min(self.max_backoff)
    }
}

/// Errors returned by lifecycle operations.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum RuntimeSupervisorError {
    #[error("runtime is already running")]
    AlreadyRunning,
    #[error("runtime cannot start from state {state}")]
    InvalidState { state: RuntimeSupervisorState },
    #[error("runtime start failed: {source}")]
    StartFailed { source: RuntimeProcessError },
    #[error("runtime start was cancelled")]
    StartCancelled,
    #[error("runtime stop failed: {source}")]
    StopFailed { source: RuntimeProcessError },
    #[error("runtime supervisor requires a Tokio runtime")]
    NoRuntime,
    #[error("runtime supervisor is unavailable")]
    Unavailable,
}

struct ActiveChild {
    child: Arc<dyn RuntimeChild>,
    generation: u64,
    stop_mode: Arc<AtomicU8>,
    stop_signal: Arc<Notify>,
}

struct Lifecycle {
    snapshot: RuntimeStateSnapshot,
    active: Option<ActiveChild>,
    next_generation: u64,
    backoff_owner: Option<u64>,
    backoff_signal: Option<Arc<Notify>>,
    starting_generation: Option<u64>,
    start_signal: Option<Arc<Notify>>,
    stop_error: Option<RuntimeProcessError>,
}

struct Shared {
    lifecycle: Mutex<Lifecycle>,
    states: watch::Sender<RuntimeStateSnapshot>,
    shutdown: watch::Sender<bool>,
    closed: AtomicBool,
}

struct MonitorContext {
    shared: Arc<Shared>,
    process: Arc<dyn RuntimeProcess>,
    clock: Arc<dyn RuntimeClock>,
    config: RuntimeSupervisorConfig,
}

impl Shared {
    fn publish(&self, lifecycle: &mut Lifecycle, state: RuntimeSupervisorState) {
        lifecycle.snapshot.state = state;
        self.states.send_replace(lifecycle.snapshot.clone());
    }
}

struct StartWaitGuard {
    shared: Arc<Shared>,
    generation: u64,
    armed: bool,
}

impl StartWaitGuard {
    fn new(shared: Arc<Shared>, generation: u64) -> Self {
        Self {
            shared,
            generation,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for StartWaitGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let shared = Arc::clone(&self.shared);
        let generation = self.generation;
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            return;
        };
        handle.spawn(async move {
            cancel_start_after_caller_drop(shared, generation).await;
        });
    }
}

async fn cancel_start_after_caller_drop(shared: Arc<Shared>, generation: u64) {
    let mut lifecycle = shared.lifecycle.lock().await;
    match lifecycle.snapshot.state {
        RuntimeSupervisorState::Starting if lifecycle.starting_generation == Some(generation) => {
            let signal = lifecycle.start_signal.take();
            lifecycle.starting_generation = None;
            lifecycle.backoff_owner = None;
            lifecycle.backoff_signal = None;
            lifecycle.snapshot.last_error = Some(RuntimeFailure::StartCancelled);
            shared.publish(&mut lifecycle, RuntimeSupervisorState::Failed);
            if let Some(signal) = signal {
                signal.notify_one();
            }
        }
        RuntimeSupervisorState::Running
            if lifecycle
                .active
                .as_ref()
                .is_some_and(|active| active.generation == generation) =>
        {
            if let Some(active) = lifecycle.active.as_ref() {
                active.stop_mode.store(STOP_FORCE, Ordering::Release);
                active.stop_signal.notify_one();
            }
            shared.publish(&mut lifecycle, RuntimeSupervisorState::Stopping);
        }
        _ => {}
    }
}

/// A bounded lifecycle supervisor for one eventual local runtime process.
///
/// The constructor does not start anything.  [`RuntimeSupervisor::start`]
/// must be called from a Tokio runtime.  The returned supervisor owns one
/// monitor task while a child is live and uses only a bounded policy; it does
/// not spawn a process by itself and is not wired into the broker yet.
pub struct RuntimeSupervisor {
    process: Arc<dyn RuntimeProcess>,
    clock: Arc<dyn RuntimeClock>,
    config: RuntimeSupervisorConfig,
    shared: Arc<Shared>,
}

impl RuntimeSupervisor {
    /// Check an established connection against the currently owned child.
    /// A restart cannot transfer an established TCP connection to another PID.
    pub async fn verify_connection(
        &self,
        local: std::net::SocketAddr,
        peer: std::net::SocketAddr,
    ) -> bool {
        let child = {
            let lifecycle = self.shared.lifecycle.lock().await;
            if lifecycle.snapshot.state != RuntimeSupervisorState::Running {
                return false;
            }
            lifecycle
                .active
                .as_ref()
                .map(|active| Arc::clone(&active.child))
        };
        child.is_some_and(|child| child.verify_connection(local, peer))
    }
    /// Construct an idle supervisor with injected process and clock adapters.
    pub fn new(
        process: Arc<dyn RuntimeProcess>,
        clock: Arc<dyn RuntimeClock>,
        config: RuntimeSupervisorConfig,
    ) -> Result<Arc<Self>, RuntimeSupervisorConfigError> {
        config.validate()?;
        let initial = RuntimeStateSnapshot {
            state: RuntimeSupervisorState::Idle,
            automatic_restarts: 0,
            last_error: None,
        };
        let (states, _) = watch::channel(initial.clone());
        let (shutdown, _) = watch::channel(false);
        Ok(Arc::new(Self {
            process,
            clock,
            config,
            shared: Arc::new(Shared {
                lifecycle: Mutex::new(Lifecycle {
                    snapshot: initial,
                    active: None,
                    next_generation: 1,
                    backoff_owner: None,
                    backoff_signal: None,
                    starting_generation: None,
                    start_signal: None,
                    stop_error: None,
                }),
                states,
                shutdown,
                closed: AtomicBool::new(false),
            }),
        }))
    }

    /// Return the latest typed lifecycle snapshot.
    #[must_use]
    pub fn snapshot(&self) -> RuntimeStateSnapshot {
        self.shared.states.borrow().clone()
    }

    /// Subscribe to lifecycle state changes.
    ///
    /// Every published state is delivered, so a caller that is waiting on the
    /// runtime can be woken by a change instead of polling. A closed channel is
    /// the terminal answer: the state will never be published again, which is the
    /// same thing a caller learns from a state that is not `Running`.
    pub fn subscribe_states(&self) -> watch::Receiver<RuntimeStateSnapshot> {
        self.shared.states.subscribe()
    }

    /// Start the single child if the supervisor is idle.
    ///
    /// A second concurrent or later call while running returns
    /// [`RuntimeSupervisorError::AlreadyRunning`] without invoking the process
    /// adapter.  Failed supervisors are terminal for this instance.
    pub async fn start(&self) -> Result<(), RuntimeSupervisorError> {
        if Handle::try_current().is_err() {
            return Err(RuntimeSupervisorError::NoRuntime);
        }

        let (generation, start_signal, result) = {
            let mut lifecycle = self.shared.lifecycle.lock().await;
            match lifecycle.snapshot.state {
                RuntimeSupervisorState::Idle => {}
                RuntimeSupervisorState::Running => {
                    return Err(RuntimeSupervisorError::AlreadyRunning);
                }
                state => return Err(RuntimeSupervisorError::InvalidState { state }),
            }

            let generation = lifecycle.next_generation;
            lifecycle.next_generation = lifecycle.next_generation.wrapping_add(1);
            let start_signal = Arc::new(Notify::new());
            let (result_tx, result) = oneshot::channel();
            lifecycle.starting_generation = Some(generation);
            lifecycle.start_signal = Some(Arc::clone(&start_signal));
            lifecycle.active = None;
            lifecycle.backoff_owner = None;
            lifecycle.backoff_signal = None;
            lifecycle.stop_error = None;
            lifecycle.snapshot.automatic_restarts = 0;
            lifecycle.snapshot.last_error = None;
            self.shared
                .publish(&mut lifecycle, RuntimeSupervisorState::Starting);
            tokio::spawn(initial_start_task(
                Arc::clone(&self.shared),
                Arc::clone(&self.process),
                Arc::clone(&self.clock),
                self.config,
                generation,
                result_tx,
            ));
            (generation, start_signal, result)
        };
        let mut start_guard = StartWaitGuard::new(Arc::clone(&self.shared), generation);
        let outcome = tokio::select! {
            result = result => result.unwrap_or(Err(RuntimeSupervisorError::Unavailable)),
            _ = start_signal.notified() => {
                let snapshot = self.snapshot();
                if matches!(snapshot.last_error, Some(RuntimeFailure::StartCancelled)) {
                    Err(RuntimeSupervisorError::StartCancelled)
                } else {
                    Err(RuntimeSupervisorError::Unavailable)
                }
            }
        };
        start_guard.disarm();
        outcome
    }

    /// Request a graceful stop and wait until the child leaves `Stopping`.
    ///
    /// The request is idempotent: idle, failed, and already-stopped
    /// supervisors return successfully.  If the caller future is cancelled
    /// after the request is published, the child monitor continues the stop.
    pub async fn stop_gracefully(&self) -> Result<(), RuntimeSupervisorError> {
        self.request_stop(STOP_GRACEFUL).await
    }

    /// Request a forced stop and wait until the child leaves `Stopping`.
    ///
    /// This is also safe to use as a cancellation operation.  Repeated calls
    /// do not create another child or another unbounded operation queue.
    pub async fn force_stop(&self) -> Result<(), RuntimeSupervisorError> {
        self.request_stop(STOP_FORCE).await
    }

    /// Alias for [`RuntimeSupervisor::force_stop`] for cancellation-oriented
    /// callers.
    pub async fn cancel(&self) -> Result<(), RuntimeSupervisorError> {
        self.force_stop().await
    }

    async fn request_stop(&self, requested_mode: u8) -> Result<(), RuntimeSupervisorError> {
        let signal = {
            let mut lifecycle = self.shared.lifecycle.lock().await;
            match lifecycle.snapshot.state {
                RuntimeSupervisorState::Idle | RuntimeSupervisorState::Failed => {
                    return Ok(());
                }
                RuntimeSupervisorState::Starting => {
                    let signal = lifecycle.start_signal.take();
                    lifecycle.starting_generation = None;
                    lifecycle.backoff_owner = None;
                    lifecycle.backoff_signal = None;
                    lifecycle.snapshot.last_error = Some(RuntimeFailure::StartCancelled);
                    self.shared
                        .publish(&mut lifecycle, RuntimeSupervisorState::Failed);
                    drop(lifecycle);
                    if let Some(signal) = signal {
                        signal.notify_one();
                    }
                    return Ok(());
                }
                RuntimeSupervisorState::BackingOff => {
                    let signal = lifecycle.backoff_signal.take();
                    lifecycle.backoff_owner = None;
                    lifecycle.snapshot.automatic_restarts = 0;
                    lifecycle.snapshot.last_error = None;
                    self.shared
                        .publish(&mut lifecycle, RuntimeSupervisorState::Idle);
                    drop(lifecycle);
                    if let Some(signal) = signal {
                        signal.notify_one();
                    }
                    return Ok(());
                }
                RuntimeSupervisorState::Running | RuntimeSupervisorState::Stopping => {
                    let active = lifecycle
                        .active
                        .as_ref()
                        .ok_or(RuntimeSupervisorError::Unavailable)?;
                    let current_mode = active.stop_mode.load(Ordering::Acquire);
                    let mode = if requested_mode == STOP_FORCE || current_mode == STOP_FORCE {
                        STOP_FORCE
                    } else {
                        STOP_GRACEFUL
                    };
                    active.stop_mode.store(mode, Ordering::Release);
                    let signal = Arc::clone(&active.stop_signal);
                    if lifecycle.snapshot.state != RuntimeSupervisorState::Stopping {
                        lifecycle.snapshot.last_error = None;
                    }
                    self.shared
                        .publish(&mut lifecycle, RuntimeSupervisorState::Stopping);
                    signal
                }
            }
        };

        signal.notify_one();
        // The stop request has been delivered to the adapter at this point, so
        // timing out here is not a failure to stop: it is a failure to observe
        // the stop.  Report it as unavailable rather than blocking forever on a
        // state transition only a live monitor task can publish.
        tokio::time::timeout(self.config.stop_confirm_timeout, self.wait_for_stop())
            .await
            .map_err(|_| RuntimeSupervisorError::Unavailable)??;
        let snapshot = self.snapshot();
        if snapshot.state == RuntimeSupervisorState::Failed
            && let Some(RuntimeFailure::Stop { source }) = snapshot.last_error
        {
            return Err(RuntimeSupervisorError::StopFailed { source });
        }
        Ok(())
    }

    async fn wait_for_stop(&self) -> Result<(), RuntimeSupervisorError> {
        let mut states = self.shared.states.subscribe();
        loop {
            let snapshot = states.borrow().clone();
            match snapshot.state {
                RuntimeSupervisorState::Stopping => {}
                RuntimeSupervisorState::Idle => return Ok(()),
                RuntimeSupervisorState::Failed => {
                    return match snapshot.last_error {
                        Some(RuntimeFailure::Stop { source }) => {
                            Err(RuntimeSupervisorError::StopFailed { source })
                        }
                        _ => Err(RuntimeSupervisorError::Unavailable),
                    };
                }
                RuntimeSupervisorState::Running | RuntimeSupervisorState::BackingOff => {
                    return Ok(());
                }
                RuntimeSupervisorState::Starting => {
                    return Err(RuntimeSupervisorError::StartCancelled);
                }
            }
            if states.changed().await.is_err() {
                return Err(RuntimeSupervisorError::Unavailable);
            }
        }
    }
}

impl Drop for RuntimeSupervisor {
    fn drop(&mut self) {
        // The monitor interprets this as a forced-stop request.  The sender is
        // retained by the supervisor only; dropping the last Arc therefore
        // cannot leave a monitor waiting on a backoff timer forever.
        self.shared.closed.store(true, Ordering::Release);
        let _ = self.shared.shutdown.send(true);
    }
}

fn attach_child(
    context: MonitorContext,
    lifecycle: &mut Lifecycle,
    generation: u64,
    child: Arc<dyn RuntimeChild>,
) {
    let shared = Arc::clone(&context.shared);
    let stop_mode = Arc::new(AtomicU8::new(STOP_NONE));
    let stop_signal = Arc::new(Notify::new());
    let monitor = tokio::spawn(monitor_child(
        context,
        Arc::clone(&child),
        generation,
        Arc::clone(&stop_mode),
        Arc::clone(&stop_signal),
    ));
    let _monitor = monitor;
    lifecycle.active = Some(ActiveChild {
        child,
        generation,
        stop_mode,
        stop_signal,
    });
    lifecycle.starting_generation = None;
    lifecycle.start_signal = None;
    lifecycle.backoff_owner = None;
    lifecycle.backoff_signal = None;
    lifecycle.stop_error = None;
    shared.publish(lifecycle, RuntimeSupervisorState::Running);
}

async fn initial_start_task(
    shared: Arc<Shared>,
    process: Arc<dyn RuntimeProcess>,
    clock: Arc<dyn RuntimeClock>,
    config: RuntimeSupervisorConfig,
    generation: u64,
    reply: oneshot::Sender<Result<(), RuntimeSupervisorError>>,
) {
    // Do not hold the lifecycle mutex while an adapter may block.
    let result = process.start().await;
    let outcome = finish_initial_start(shared, generation, result, process, clock, config).await;
    let _ = reply.send(outcome);
}

async fn finish_initial_start(
    shared: Arc<Shared>,
    generation: u64,
    result: Result<Arc<dyn RuntimeChild>, RuntimeProcessError>,
    process: Arc<dyn RuntimeProcess>,
    clock: Arc<dyn RuntimeClock>,
    config: RuntimeSupervisorConfig,
) -> Result<(), RuntimeSupervisorError> {
    match result {
        Ok(child) => {
            let attached = {
                let mut lifecycle = shared.lifecycle.lock().await;
                if !shared.closed.load(Ordering::Acquire)
                    && lifecycle.snapshot.state == RuntimeSupervisorState::Starting
                    && lifecycle.starting_generation == Some(generation)
                {
                    attach_child(
                        MonitorContext {
                            shared: Arc::clone(&shared),
                            process,
                            clock,
                            config,
                        },
                        &mut lifecycle,
                        generation,
                        Arc::clone(&child),
                    );
                    true
                } else {
                    false
                }
            };
            if attached {
                Ok(())
            } else {
                stop_late_child(&shared, generation, child).await;
                let snapshot = shared.states.borrow().clone();
                match snapshot.last_error {
                    Some(RuntimeFailure::Stop { source }) => {
                        Err(RuntimeSupervisorError::StopFailed { source })
                    }
                    _ => Err(RuntimeSupervisorError::StartCancelled),
                }
            }
        }
        Err(source) => {
            let mut lifecycle = shared.lifecycle.lock().await;
            if !shared.closed.load(Ordering::Acquire)
                && lifecycle.snapshot.state == RuntimeSupervisorState::Starting
                && lifecycle.starting_generation == Some(generation)
            {
                lifecycle.starting_generation = None;
                lifecycle.start_signal = None;
                lifecycle.snapshot.last_error = Some(RuntimeFailure::Start { source });
                shared.publish(&mut lifecycle, RuntimeSupervisorState::Failed);
                Err(RuntimeSupervisorError::StartFailed { source })
            } else {
                Err(RuntimeSupervisorError::StartCancelled)
            }
        }
    }
}

async fn stop_late_child(shared: &Arc<Shared>, generation: u64, child: Arc<dyn RuntimeChild>) {
    let result = child.force_stop().await;
    let mut lifecycle = shared.lifecycle.lock().await;
    let owns_terminal_start = lifecycle.starting_generation == Some(generation)
        || matches!(
            lifecycle.snapshot.last_error,
            Some(RuntimeFailure::StartCancelled | RuntimeFailure::Stop { .. })
        );
    if !owns_terminal_start {
        return;
    }
    lifecycle.starting_generation = None;
    lifecycle.start_signal = None;
    lifecycle.backoff_owner = None;
    lifecycle.backoff_signal = None;
    if let Err(source) = result {
        lifecycle.snapshot.last_error = Some(RuntimeFailure::Stop { source });
    } else if !matches!(
        lifecycle.snapshot.last_error,
        Some(RuntimeFailure::Stop { .. })
    ) {
        lifecycle.snapshot.last_error = Some(RuntimeFailure::StartCancelled);
    }
    shared.publish(&mut lifecycle, RuntimeSupervisorState::Failed);
}

async fn monitor_child(
    context: MonitorContext,
    child: Arc<dyn RuntimeChild>,
    generation: u64,
    stop_mode: Arc<AtomicU8>,
    stop_signal: Arc<Notify>,
) {
    let MonitorContext {
        shared,
        process,
        clock,
        config,
    } = context;
    let mut shutdown = shared.shutdown.subscribe();
    let wait = child.wait();
    tokio::pin!(wait);
    // A graceful request can be upgraded to force after it has been accepted.
    // Keep the highest successfully issued mode so repeated notifications do
    // not invoke the adapter more than once, while a force request can still
    // interrupt a graceful adapter future.
    let mut handled_stop_mode = STOP_NONE;
    let mut stop_error_for_mode = false;
    let mut shutdown_seen = false;
    let exit_result = loop {
        if shutdown_seen {
            break (&mut wait).await;
        }

        let requested_mode = stop_mode.load(Ordering::Acquire);
        if requested_mode > handled_stop_mode && !stop_error_for_mode {
            let mode = requested_mode;
            if issue_stop(
                &shared,
                generation,
                &child,
                &stop_mode,
                &stop_signal,
                &mut shutdown,
            )
            .await
            {
                handled_stop_mode = stop_mode.load(Ordering::Acquire).max(mode);
                stop_error_for_mode = false;
            } else {
                stop_error_for_mode = true;
            }
            continue;
        }

        tokio::select! {
            result = &mut wait => {
                // If exit and a stop request become ready in the same poll,
                // issue the stop before classifying the exit as intentional.
                let requested_mode = stop_mode.load(Ordering::Acquire);
                if requested_mode > handled_stop_mode && !stop_error_for_mode {
                    let _ = issue_stop(
                        &shared,
                        generation,
                        &child,
                        &stop_mode,
                        &stop_signal,
                        &mut shutdown,
                    )
                    .await;
                }
                break result;
            }
            _ = stop_signal.notified() => {
                let requested_mode = stop_mode.load(Ordering::Acquire);
                if requested_mode > handled_stop_mode {
                    // A new notification permits a retry after an adapter
                    // error, and also wakes a force upgrade.
                    stop_error_for_mode = false;
                }
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    shutdown_seen = true;
                    stop_mode.store(STOP_FORCE, Ordering::Release);
                    if let Err(error) = child.force_stop().await {
                        record_stop_error(&shared, generation, error).await;
                    }
                    handled_stop_mode = STOP_FORCE;
                    stop_error_for_mode = false;
                }
            }
        }
    };

    handle_child_exit(
        shared,
        generation,
        exit_result,
        process,
        clock,
        config,
        &mut shutdown,
    )
    .await;
}

async fn issue_stop(
    shared: &Arc<Shared>,
    generation: u64,
    child: &Arc<dyn RuntimeChild>,
    stop_mode: &AtomicU8,
    stop_signal: &Notify,
    shutdown: &mut watch::Receiver<bool>,
) -> bool {
    match perform_stop(child, stop_mode, stop_signal, shutdown).await {
        Ok(()) => true,
        Err(error) => {
            record_stop_error(shared, generation, error).await;
            false
        }
    }
}

async fn perform_stop(
    child: &Arc<dyn RuntimeChild>,
    stop_mode: &AtomicU8,
    stop_signal: &Notify,
    shutdown: &mut watch::Receiver<bool>,
) -> Result<(), RuntimeProcessError> {
    loop {
        match stop_mode.load(Ordering::Acquire) {
            STOP_NONE => return Ok(()),
            STOP_FORCE => return child.force_stop().await,
            STOP_GRACEFUL => {
                let graceful = child.graceful_stop();
                tokio::pin!(graceful);
                tokio::select! {
                    result = &mut graceful => {
                        if stop_mode.load(Ordering::Acquire) == STOP_FORCE {
                            continue;
                        }
                        return result;
                    }
                    // A graceful request can be upgraded to force while its
                    // adapter future is pending.  Other duplicate stop
                    // notifications are deliberately not selected here.
                    _ = stop_signal.notified(), if stop_mode.load(Ordering::Acquire) == STOP_FORCE => {
                        continue;
                    }
                    changed = shutdown.changed() => {
                        if changed.is_err() || *shutdown.borrow() {
                            stop_mode.store(STOP_FORCE, Ordering::Release);
                            return child.force_stop().await;
                        }
                    }
                }
            }
            _ => return Ok(()),
        }
    }
}

async fn record_stop_error(shared: &Arc<Shared>, generation: u64, error: RuntimeProcessError) {
    let mut lifecycle = shared.lifecycle.lock().await;
    if lifecycle
        .active
        .as_ref()
        .is_some_and(|active| active.generation == generation)
    {
        lifecycle.stop_error = Some(error);
        lifecycle.snapshot.last_error = Some(RuntimeFailure::Stop { source: error });
        shared.publish(&mut lifecycle, RuntimeSupervisorState::Failed);
    }
}

async fn handle_child_exit(
    shared: Arc<Shared>,
    generation: u64,
    exit_result: Result<(), RuntimeProcessError>,
    process: Arc<dyn RuntimeProcess>,
    clock: Arc<dyn RuntimeClock>,
    config: RuntimeSupervisorConfig,
    shutdown: &mut watch::Receiver<bool>,
) {
    let mut pending_cause = exit_result.err();
    let mut first_restart = true;
    loop {
        let (delay, signal) = {
            let mut lifecycle = shared.lifecycle.lock().await;
            if shared.closed.load(Ordering::Acquire) {
                return;
            }
            if lifecycle.snapshot.state == RuntimeSupervisorState::Failed {
                lifecycle.active = None;
                lifecycle.backoff_owner = None;
                lifecycle.backoff_signal = None;
                lifecycle.starting_generation = None;
                lifecycle.start_signal = None;
                return;
            }
            let owns_exit = lifecycle
                .active
                .as_ref()
                .is_some_and(|active| active.generation == generation)
                || (lifecycle.snapshot.state == RuntimeSupervisorState::BackingOff
                    && lifecycle.backoff_owner == Some(generation));
            if !owns_exit {
                return;
            }
            lifecycle.active = None;
            let stop_requested = lifecycle.snapshot.state == RuntimeSupervisorState::Stopping;
            let stop_error = if stop_requested {
                lifecycle.stop_error.take()
            } else {
                lifecycle.stop_error = None;
                None
            };

            if stop_requested {
                lifecycle.backoff_owner = None;
                lifecycle.backoff_signal = None;
                lifecycle.starting_generation = None;
                lifecycle.start_signal = None;
                if let Some(source) = stop_error {
                    lifecycle.snapshot.last_error = Some(RuntimeFailure::Stop { source });
                    shared.publish(&mut lifecycle, RuntimeSupervisorState::Failed);
                } else {
                    lifecycle.snapshot.automatic_restarts = 0;
                    lifecycle.snapshot.last_error = None;
                    shared.publish(&mut lifecycle, RuntimeSupervisorState::Idle);
                }
                return;
            }

            if lifecycle.snapshot.automatic_restarts >= config.max_restarts {
                lifecycle.backoff_owner = None;
                lifecycle.backoff_signal = None;
                lifecycle.snapshot.last_error = Some(RuntimeFailure::RestartLimitExceeded {
                    limit: config.max_restarts,
                    cause: pending_cause,
                });
                shared.publish(&mut lifecycle, RuntimeSupervisorState::Failed);
                return;
            }

            let attempt = lifecycle.snapshot.automatic_restarts + 1;
            lifecycle.snapshot.automatic_restarts = attempt;
            let failure = if first_restart {
                RuntimeFailure::UnexpectedExit {
                    cause: pending_cause,
                }
            } else {
                RuntimeFailure::Restart {
                    cause: pending_cause,
                }
            };
            let signal = Arc::new(Notify::new());
            lifecycle.backoff_owner = Some(generation);
            lifecycle.backoff_signal = Some(Arc::clone(&signal));
            lifecycle.snapshot.last_error = Some(failure);
            shared.publish(&mut lifecycle, RuntimeSupervisorState::BackingOff);
            (config.delay_for(attempt), signal)
        };
        first_restart = false;

        if !wait_for_backoff(clock.as_ref(), delay, signal.as_ref(), shutdown).await {
            clear_backoff(&shared, generation).await;
            return;
        }

        // Move the lifecycle to Starting before invoking the factory, but do
        // not hold the lifecycle mutex while the factory future is pending.
        // A stop can therefore publish Failed immediately and invalidate this
        // generation; a late child is then stopped outside the lock.
        let replacement_generation = {
            let mut lifecycle = shared.lifecycle.lock().await;
            if shared.closed.load(Ordering::Acquire)
                || lifecycle.snapshot.state != RuntimeSupervisorState::BackingOff
                || lifecycle.backoff_owner != Some(generation)
            {
                return;
            }
            let replacement_generation = lifecycle.next_generation;
            lifecycle.next_generation = lifecycle.next_generation.wrapping_add(1);
            let start_signal = Arc::new(Notify::new());
            lifecycle.starting_generation = Some(replacement_generation);
            lifecycle.start_signal = Some(start_signal);
            lifecycle.backoff_owner = None;
            lifecycle.backoff_signal = None;
            lifecycle.snapshot.last_error = None;
            shared.publish(&mut lifecycle, RuntimeSupervisorState::Starting);
            replacement_generation
        };

        let start_result = process.start().await;
        match start_result {
            Ok(child) => {
                let attached = {
                    let mut lifecycle = shared.lifecycle.lock().await;
                    if !shared.closed.load(Ordering::Acquire)
                        && lifecycle.snapshot.state == RuntimeSupervisorState::Starting
                        && lifecycle.starting_generation == Some(replacement_generation)
                    {
                        attach_child(
                            MonitorContext {
                                shared: Arc::clone(&shared),
                                process: Arc::clone(&process),
                                clock: Arc::clone(&clock),
                                config,
                            },
                            &mut lifecycle,
                            replacement_generation,
                            Arc::clone(&child),
                        );
                        true
                    } else {
                        false
                    }
                };
                if !attached {
                    stop_late_child(&shared, replacement_generation, child).await;
                }
                return;
            }
            Err(source) => {
                let mut lifecycle = shared.lifecycle.lock().await;
                if shared.closed.load(Ordering::Acquire)
                    || lifecycle.snapshot.state != RuntimeSupervisorState::Starting
                    || lifecycle.starting_generation != Some(replacement_generation)
                {
                    return;
                }
                lifecycle.starting_generation = None;
                lifecycle.start_signal = None;
                if lifecycle.snapshot.automatic_restarts >= config.max_restarts {
                    lifecycle.backoff_owner = None;
                    lifecycle.backoff_signal = None;
                    lifecycle.snapshot.last_error = Some(RuntimeFailure::RestartLimitExceeded {
                        limit: config.max_restarts,
                        cause: Some(source),
                    });
                    shared.publish(&mut lifecycle, RuntimeSupervisorState::Failed);
                    return;
                }
                pending_cause = Some(source);
                let signal = Arc::new(Notify::new());
                lifecycle.backoff_owner = Some(generation);
                lifecycle.backoff_signal = Some(signal);
                lifecycle.snapshot.last_error = Some(RuntimeFailure::Restart {
                    cause: pending_cause,
                });
                shared.publish(&mut lifecycle, RuntimeSupervisorState::BackingOff);
            }
        }
    }
}

async fn wait_for_backoff(
    clock: &dyn RuntimeClock,
    delay: Duration,
    signal: &Notify,
    shutdown: &mut watch::Receiver<bool>,
) -> bool {
    let sleep = clock.sleep(delay);
    tokio::pin!(sleep);
    tokio::select! {
        _ = &mut sleep => true,
        _ = signal.notified() => false,
        changed = shutdown.changed() => !(changed.is_err() || *shutdown.borrow()),
    }
}

async fn clear_backoff(shared: &Arc<Shared>, generation: u64) {
    let mut lifecycle = shared.lifecycle.lock().await;
    if lifecycle.backoff_owner == Some(generation)
        && lifecycle.snapshot.state == RuntimeSupervisorState::BackingOff
    {
        lifecycle.backoff_owner = None;
        lifecycle.backoff_signal = None;
        lifecycle.snapshot.automatic_restarts = 0;
        lifecycle.snapshot.last_error = None;
        shared.publish(&mut lifecycle, RuntimeSupervisorState::Idle);
    }
}
