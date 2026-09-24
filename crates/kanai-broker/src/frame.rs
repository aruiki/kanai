//! Bounded length-prefixed framing for broker messages.
//!
//! The wire header is intentionally small and endian-explicit so a future
//! Windows named-pipe adapter can share it with a TIP without sharing a Rust
//! I/O implementation:
//!
//! ```text
//! KBF1 | u32 big-endian payload length | UTF-8 JSON payload
//! ```
//!
//! No allocation is made from an untrusted length until it has been checked
//! against the configured limit.

use std::collections::VecDeque;
use std::io::{self, Read, Write};

use thiserror::Error;

/// Default maximum JSON payload accepted by the broker transport.
pub const DEFAULT_MAX_FRAME_BYTES: usize = 1024 * 1024;
/// Alias for the default bounded payload contract.
pub const MAX_FRAME_BYTES: usize = DEFAULT_MAX_FRAME_BYTES;
/// Magic bytes at the beginning of every frame.
pub const FRAME_MAGIC: [u8; 4] = *b"KBF1";
/// Magic plus the big-endian payload length.
pub const FRAME_HEADER_BYTES: usize = 8;

/// An already validated frame payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    payload: Vec<u8>,
}

impl Frame {
    /// Construct a frame using the default payload limit.
    pub fn new(payload: impl Into<Vec<u8>>) -> Result<Self, FrameError> {
        Self::with_limit(payload, DEFAULT_MAX_FRAME_BYTES)
    }

    /// Construct a frame after checking an explicit payload limit.
    pub fn with_limit(
        payload: impl Into<Vec<u8>>,
        max_frame_bytes: usize,
    ) -> Result<Self, FrameError> {
        let payload = payload.into();
        validate_payload_length(payload.len(), max_frame_bytes)?;
        Ok(Self { payload })
    }

    #[must_use]
    pub fn payload(&self) -> &[u8] {
        &self.payload
    }

    #[must_use]
    pub fn into_payload(self) -> Vec<u8> {
        self.payload
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.payload.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.payload.is_empty()
    }
}

/// A decoded frame and the number of bytes consumed from its input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedFrame {
    pub payload: Vec<u8>,
    pub consumed: usize,
}

/// Errors produced by the bounded framing layer.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum FrameError {
    #[error("frame payload must not be empty")]
    EmptyPayload,
    #[error("frame payload is {size} bytes; maximum is {max} bytes")]
    PayloadTooLarge { size: usize, max: usize },
    #[error("frame limit must be greater than zero (got {max})")]
    InvalidLimit { max: usize },
    #[error("invalid frame magic")]
    InvalidMagic,
    #[error("frame payload length is zero")]
    ZeroLength,
    #[error("frame payload length is not representable on the wire")]
    LengthOverflow,
    #[error("truncated frame header")]
    TruncatedHeader,
    #[error("truncated frame payload")]
    TruncatedPayload,
    #[error("frame input contains trailing bytes")]
    TrailingBytes,
    #[error("frame decoder buffer exceeded its bounded limit")]
    BufferOverflow,
    #[error("frame decoder ended with an incomplete frame")]
    IncompleteFrame,
    #[error("frame I/O failed: {0}")]
    Io(String),
}

/// Stateless encoder/decoder for one complete frame.
#[derive(Debug, Clone)]
pub struct FrameCodec {
    max_frame_bytes: usize,
}

impl FrameCodec {
    /// Create a codec with a non-zero maximum payload size.
    pub fn new(max_frame_bytes: usize) -> Result<Self, FrameError> {
        if max_frame_bytes == 0 {
            return Err(FrameError::InvalidLimit { max: 0 });
        }
        if max_frame_bytes > u32::MAX as usize {
            return Err(FrameError::LengthOverflow);
        }
        Ok(Self { max_frame_bytes })
    }

    #[must_use]
    pub fn max_frame_bytes(&self) -> usize {
        self.max_frame_bytes
    }

    /// Encode a payload into one complete wire frame.
    pub fn encode(&self, payload: &[u8]) -> Result<Vec<u8>, FrameError> {
        validate_payload_length(payload.len(), self.max_frame_bytes)?;
        let mut output = Vec::with_capacity(FRAME_HEADER_BYTES + payload.len());
        output.extend_from_slice(&FRAME_MAGIC);
        output.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        output.extend_from_slice(payload);
        Ok(output)
    }

    /// Decode exactly one frame.  Trailing bytes are rejected so callers do
    /// not accidentally accept an unbounded concatenated payload as one
    /// message; streaming callers should use [`FrameDecoder`].
    pub fn decode(&self, input: &[u8]) -> Result<DecodedFrame, FrameError> {
        if input.len() < FRAME_HEADER_BYTES {
            return Err(FrameError::TruncatedHeader);
        }
        let payload_len = parse_payload_len(input, self.max_frame_bytes)?;
        let total_len = FRAME_HEADER_BYTES
            .checked_add(payload_len)
            .ok_or(FrameError::LengthOverflow)?;
        if input.len() < total_len {
            return Err(FrameError::TruncatedPayload);
        }
        if input.len() > total_len {
            return Err(FrameError::TrailingBytes);
        }
        Ok(DecodedFrame {
            payload: input[FRAME_HEADER_BYTES..total_len].to_vec(),
            consumed: total_len,
        })
    }
}

/// Incremental decoder for transports that deliver arbitrary byte chunks.
#[derive(Debug, Clone)]
pub struct FrameDecoder {
    max_frame_bytes: usize,
    buffer: Vec<u8>,
}

impl FrameDecoder {
    pub fn new(max_frame_bytes: usize) -> Result<Self, FrameError> {
        Ok(Self {
            max_frame_bytes: FrameCodec::new(max_frame_bytes)?.max_frame_bytes,
            buffer: Vec::new(),
        })
    }

    #[must_use]
    pub fn max_frame_bytes(&self) -> usize {
        self.max_frame_bytes
    }

    /// Add bytes and return every complete frame now available.
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Vec<u8>>, FrameError> {
        let mut frames = Vec::new();
        for byte in bytes {
            let max_buffer_len = FRAME_HEADER_BYTES
                .checked_add(self.max_frame_bytes)
                .ok_or(FrameError::BufferOverflow)?;
            if self.buffer.len() >= max_buffer_len {
                self.buffer.clear();
                return Err(FrameError::BufferOverflow);
            }
            self.buffer.push(*byte);
            while let Some(payload) = self.take_frame()? {
                frames.push(payload);
            }
        }
        Ok(frames)
    }

    /// Finish a stream and reject an incomplete frame.
    pub fn finish(&self) -> Result<(), FrameError> {
        if self.buffer.is_empty() {
            Ok(())
        } else {
            Err(FrameError::IncompleteFrame)
        }
    }

    pub fn reset(&mut self) {
        self.buffer.clear();
    }

    fn take_frame(&mut self) -> Result<Option<Vec<u8>>, FrameError> {
        if self.buffer.len() < FRAME_HEADER_BYTES {
            return Ok(None);
        }
        let payload_len = parse_payload_len(&self.buffer, self.max_frame_bytes)?;
        let total_len = FRAME_HEADER_BYTES
            .checked_add(payload_len)
            .ok_or(FrameError::LengthOverflow)?;
        if self.buffer.len() < total_len {
            return Ok(None);
        }
        let payload = self.buffer[FRAME_HEADER_BYTES..total_len].to_vec();
        self.buffer.drain(..total_len);
        Ok(Some(payload))
    }
}

/// A synchronous `Read + Write` adapter.  It is useful for tests and for a
/// future blocking named-pipe wrapper, but it is not a Windows pipe server.
#[derive(Debug)]
pub struct FramedIo<T> {
    io: T,
    codec: FrameCodec,
}

impl<T> FramedIo<T> {
    pub fn new(io: T, max_frame_bytes: usize) -> Result<Self, FrameError> {
        Ok(Self {
            io,
            codec: FrameCodec::new(max_frame_bytes)?,
        })
    }

    #[must_use]
    pub fn max_frame_bytes(&self) -> usize {
        self.codec.max_frame_bytes()
    }

    pub fn get_ref(&self) -> &T {
        &self.io
    }

    pub fn get_mut(&mut self) -> &mut T {
        &mut self.io
    }

    pub fn into_inner(self) -> T {
        self.io
    }
}

impl<T: Read + Write> FramedIo<T> {
    pub fn send_payload(&mut self, payload: &[u8]) -> Result<(), FrameError> {
        let frame = self.codec.encode(payload)?;
        self.io
            .write_all(&frame)
            .map_err(|error| FrameError::Io(error.to_string()))
    }

    /// Read one frame.  `Ok(None)` means a clean EOF occurred before a header;
    /// a partial header or payload is an error.
    pub fn receive_payload(&mut self) -> Result<Option<Vec<u8>>, FrameError> {
        let mut header = [0_u8; FRAME_HEADER_BYTES];
        if !read_header(&mut self.io, &mut header)? {
            return Ok(None);
        }
        let payload_len = parse_payload_len(&header, self.codec.max_frame_bytes())?;
        let mut payload = vec![0_u8; payload_len];
        self.io
            .read_exact(&mut payload)
            .map_err(|error| FrameError::Io(error.to_string()))?;
        Ok(Some(payload))
    }
}

/// A bounded in-memory transport useful for Linux tests and contract tests.
#[derive(Debug, Clone)]
pub struct MemoryTransport {
    pub(crate) incoming: VecDeque<Frame>,
    pub(crate) outgoing: Vec<Frame>,
    pub(crate) max_frame_bytes: usize,
    pub(crate) max_queued_bytes: usize,
    pub(crate) queued_bytes: usize,
    pub(crate) closed: bool,
}

impl MemoryTransport {
    pub fn new(max_frame_bytes: usize) -> Result<Self, FrameError> {
        let _codec = FrameCodec::new(max_frame_bytes)?;
        Ok(Self {
            incoming: VecDeque::new(),
            outgoing: Vec::new(),
            max_frame_bytes,
            max_queued_bytes: max_frame_bytes.saturating_mul(8).max(max_frame_bytes),
            queued_bytes: 0,
            closed: false,
        })
    }

    pub fn with_queue_limit(
        max_frame_bytes: usize,
        max_queued_bytes: usize,
    ) -> Result<Self, FrameError> {
        let _codec = FrameCodec::new(max_frame_bytes)?;
        if max_queued_bytes == 0 {
            return Err(FrameError::InvalidLimit { max: 0 });
        }
        Ok(Self {
            incoming: VecDeque::new(),
            outgoing: Vec::new(),
            max_frame_bytes,
            max_queued_bytes,
            queued_bytes: 0,
            closed: false,
        })
    }

    #[must_use]
    pub fn queued_bytes(&self) -> usize {
        self.queued_bytes
    }

    pub fn push_incoming(&mut self, payload: impl Into<Vec<u8>>) -> Result<(), FrameError> {
        let frame = Frame::with_limit(payload, self.max_frame_bytes)?;
        self.enqueue_incoming(frame)
    }

    pub fn take_outgoing(&mut self) -> Vec<Vec<u8>> {
        let outgoing = self
            .outgoing
            .drain(..)
            .map(Frame::into_payload)
            .collect::<Vec<_>>();
        self.queued_bytes = self
            .queued_bytes
            .saturating_sub(outgoing.iter().map(Vec::len).sum());
        outgoing
    }

    pub fn close(&mut self) {
        self.closed = true;
    }

    fn enqueue_incoming(&mut self, frame: Frame) -> Result<(), FrameError> {
        if self.closed {
            return Err(FrameError::Io("transport is closed".to_owned()));
        }
        let next_len = self
            .queued_bytes
            .checked_add(frame.len())
            .ok_or(FrameError::BufferOverflow)?;
        if next_len > self.max_queued_bytes {
            return Err(FrameError::BufferOverflow);
        }
        self.queued_bytes = next_len;
        self.incoming.push_back(frame);
        Ok(())
    }
}

fn validate_payload_length(size: usize, max_frame_bytes: usize) -> Result<(), FrameError> {
    if max_frame_bytes == 0 {
        return Err(FrameError::InvalidLimit { max: 0 });
    }
    if size == 0 {
        return Err(FrameError::EmptyPayload);
    }
    if size > max_frame_bytes {
        return Err(FrameError::PayloadTooLarge {
            size,
            max: max_frame_bytes,
        });
    }
    if size > u32::MAX as usize {
        return Err(FrameError::LengthOverflow);
    }
    Ok(())
}

fn parse_payload_len(input: &[u8], max_frame_bytes: usize) -> Result<usize, FrameError> {
    if input.len() < FRAME_HEADER_BYTES {
        return Err(FrameError::TruncatedHeader);
    }
    if input[..FRAME_MAGIC.len()] != FRAME_MAGIC {
        return Err(FrameError::InvalidMagic);
    }
    let length_bytes: [u8; 4] = input[FRAME_MAGIC.len()..FRAME_HEADER_BYTES]
        .try_into()
        .map_err(|_| FrameError::TruncatedHeader)?;
    let payload_len = u32::from_be_bytes(length_bytes) as usize;
    if payload_len == 0 {
        return Err(FrameError::ZeroLength);
    }
    if payload_len > max_frame_bytes {
        return Err(FrameError::PayloadTooLarge {
            size: payload_len,
            max: max_frame_bytes,
        });
    }
    Ok(payload_len)
}

fn read_header<T: Read>(
    io: &mut T,
    header: &mut [u8; FRAME_HEADER_BYTES],
) -> Result<bool, FrameError> {
    let mut read = 0;
    while read < header.len() {
        match io.read(&mut header[read..]) {
            Ok(0) if read == 0 => return Ok(false),
            Ok(0) => {
                return Err(FrameError::Io("unexpected end of frame header".to_owned()));
            }
            Ok(count) => read += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(FrameError::Io(error.to_string())),
        }
    }
    Ok(true)
}
