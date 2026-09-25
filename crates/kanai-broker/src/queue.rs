//! Bounded asynchronous queue for optional local enhancements.
//!
//! The broker's per-key path only admits an immutable generation token and a
//! bounded request to this queue. Model work runs on separate Tokio tasks and
//! can therefore time out, be cancelled, or become stale without holding the
//! session owner lock or delaying Mozc conversion.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Weak};

use thiserror::Error;
use tokio::sync::{Mutex, Notify};

use crate::{
    CancellationToken, EnhancementBackend, EnhancementCoordinator, EnhancementPolicy,
    EnhancementReason, GenerationToken, RequestCommand, RequestEnvelope, ResponseEnvelope,
};

/// Hard upper bound for queued (not currently running) optional jobs.
pub const MAX_ENHANCEMENT_QUEUE_CAPACITY: usize = 64;
/// Hard upper bound for optional worker tasks owned by one broker process.
pub const MAX_ENHANCEMENT_WORKERS: usize = 8;

/// Queue configuration/admission failures. These are deliberately distinct
/// from provider failures: a saturated queue must return the Mozc baseline
/// without starting a model call.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum EnhancementQueueError {
    #[error("optional enhancement queue is full")]
    Full,
    #[error("optional enhancement queue is closed")]
    Closed,
    #[error("optional enhancement queue capacity is outside 1..=64")]
    InvalidCapacity,
    #[error("optional enhancement worker count is outside 1..=8")]
    InvalidWorkers,
    #[error("optional enhancement queue requires a Tokio runtime")]
    NoRuntime,
}

struct EnhancementJob {
    envelope: RequestEnvelope,
    token: GenerationToken,
    cancellation: CancellationToken,
    reply: tokio::sync::oneshot::Sender<ResponseEnvelope>,
}

struct QueueState {
    jobs: VecDeque<EnhancementJob>,
    latest: HashMap<u64, (u64, CancellationToken)>,
    closed: bool,
}

struct QueueShared {
    state: Mutex<QueueState>,
    wake: Notify,
}

/// A bounded multi-worker queue in front of [`EnhancementCoordinator`].
///
/// Admission uses a non-blocking length check. A saturated optional queue is
/// not allowed to create an unbounded backlog or make a caller wait behind
/// stale work; the caller receives a deterministic baseline response instead.
pub struct EnhancementQueue<E: EnhancementBackend> {
    shared: Arc<QueueShared>,
    coordinator: Arc<EnhancementCoordinator<E>>,
    capacity: usize,
}

impl<E: EnhancementBackend> std::fmt::Debug for EnhancementQueue<E>
where
    E: 'static,
{
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EnhancementQueue")
            .field("capacity", &self.capacity)
            .finish()
    }
}

impl<E: EnhancementBackend> EnhancementQueue<E>
where
    E: Send + Sync + 'static,
{
    /// Start a queue with a provider and policy.
    pub fn start(
        backend: E,
        policy: EnhancementPolicy,
        capacity: usize,
        workers: usize,
    ) -> Result<Self, EnhancementQueueError> {
        Self::from_coordinator(
            Arc::new(EnhancementCoordinator::with_policy(backend, policy)),
            capacity,
            workers,
        )
    }

    /// Start a queue around an already configured coordinator. This is useful
    /// for embedding the broker in a host that owns model lifecycle itself.
    pub fn from_coordinator(
        coordinator: Arc<EnhancementCoordinator<E>>,
        capacity: usize,
        workers: usize,
    ) -> Result<Self, EnhancementQueueError> {
        if capacity == 0 || capacity > MAX_ENHANCEMENT_QUEUE_CAPACITY {
            return Err(EnhancementQueueError::InvalidCapacity);
        }
        if workers == 0 || workers > MAX_ENHANCEMENT_WORKERS {
            return Err(EnhancementQueueError::InvalidWorkers);
        }
        if tokio::runtime::Handle::try_current().is_err() {
            return Err(EnhancementQueueError::NoRuntime);
        }
        let shared = Arc::new(QueueShared {
            state: Mutex::new(QueueState {
                jobs: VecDeque::with_capacity(capacity),
                latest: HashMap::new(),
                closed: false,
            }),
            wake: Notify::new(),
        });
        for _ in 0..workers {
            let weak = Arc::downgrade(&shared);
            let coordinator = Arc::clone(&coordinator);
            tokio::spawn(async move {
                while let Some(job) = pop_job(weak.clone()).await {
                    let session_id = job.envelope.command.session_id();
                    let request_id = job.envelope.request_id;
                    // A disconnected native client does not need a model
                    // call, but the coordinator still owns the authoritative
                    // timeout/cancellation path for connected clients.
                    if !job.reply.is_closed() {
                        let response = coordinator
                            .handle(job.envelope, job.token, job.cancellation)
                            .await;
                        let _ = job.reply.send(response);
                    }
                    finish_latest(&weak, session_id, request_id).await;
                }
            });
        }
        Ok(Self {
            shared,
            coordinator,
            capacity,
        })
    }

    /// Admit one optional request without waiting for queue capacity.
    pub async fn submit(
        &self,
        envelope: RequestEnvelope,
        token: GenerationToken,
        cancellation: CancellationToken,
    ) -> Result<ResponseEnvelope, EnhancementQueueError> {
        let (reply, response) = tokio::sync::oneshot::channel();
        let mut state = self.shared.state.lock().await;
        if state.closed {
            return Err(EnhancementQueueError::Closed);
        }
        if state.jobs.len() >= self.capacity {
            return Err(EnhancementQueueError::Full);
        }
        if let Some(session_id) = envelope.command.session_id() {
            if let Some((_, previous)) = state.latest.remove(&session_id) {
                previous.cancel();
            }
            state
                .latest
                .insert(session_id, (envelope.request_id, cancellation.clone()));
        }
        state.jobs.push_back(EnhancementJob {
            envelope,
            token,
            cancellation,
            reply,
        });
        drop(state);
        self.shared.wake.notify_one();
        response.await.map_err(|_| EnhancementQueueError::Closed)
    }

    /// Return a bounded baseline response without invoking the provider.
    pub fn overflow_response(
        &self,
        request_id: u64,
        token: &GenerationToken,
        command: &RequestCommand,
    ) -> ResponseEnvelope {
        self.coordinator.fallback_without_provider(
            request_id,
            token,
            command,
            EnhancementReason::ProviderUnavailable,
        )
    }

    pub fn cancel_request(&self, request_id: u64) -> bool {
        self.coordinator.cancel_request(request_id)
    }

    pub fn close(&self) {
        // There is no async lock in this control operation. The flag is set
        // under the same mutex by an async best-effort task; callers should
        // treat close as a lifecycle hint and never depend on its latency.
        let shared = Arc::clone(&self.shared);
        tokio::spawn(async move {
            let mut state = shared.state.lock().await;
            state.closed = true;
            for (_, token) in state.latest.drain() {
                token.1.cancel();
            }
            shared.wake.notify_waiters();
        });
    }

    #[must_use]
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    #[must_use]
    pub async fn pending(&self) -> usize {
        self.shared.state.lock().await.jobs.len()
    }

    #[must_use]
    pub async fn is_closed(&self) -> bool {
        self.shared.state.lock().await.closed
    }
}

impl<E: EnhancementBackend> Drop for EnhancementQueue<E> {
    fn drop(&mut self) {
        // Workers hold only Weak references, so this is the last strong owner
        // in normal use. Marking the state closed wakes any worker that still
        // has a temporary upgraded reference.
        let shared = Arc::clone(&self.shared);
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                let mut state = shared.state.lock().await;
                state.closed = true;
                for (_, token) in state.latest.drain() {
                    token.1.cancel();
                }
                shared.wake.notify_waiters();
            });
        }
    }
}

async fn finish_latest(weak: &Weak<QueueShared>, session_id: Option<u64>, request_id: u64) {
    let Some(shared) = weak.upgrade() else {
        return;
    };
    let mut state = shared.state.lock().await;
    if let Some(session_id) = session_id
        && state
            .latest
            .get(&session_id)
            .is_some_and(|(latest_request, _)| *latest_request == request_id)
    {
        state.latest.remove(&session_id);
    }
}

async fn pop_job(weak: Weak<QueueShared>) -> Option<EnhancementJob> {
    loop {
        let shared = weak.upgrade()?;
        let mut state = shared.state.lock().await;
        if let Some(job) = state.jobs.pop_front() {
            return Some(job);
        }
        if state.closed {
            return None;
        }
        drop(state);
        shared.wake.notified().await;
    }
}
