## 0.0.1

- Initial release
- Native PTY implementation using FFI and C bridge
- Support for spawning processes with PTY using posix_spawn
- Stream-based output reading with proper UTF-8 boundary handling
- Write capability for sending input to processes
- Window resize support
- Automatic memory management and process cleanup
- Thread-safe implementation with background I/O
- Environment variable support for spawned processes
- Awaitable exit code monitoring
- Signal sending capability (kill method)
- Working directory support
- Terminal mode control (canonical, cbreak, raw)
- Comprehensive examples and tests
- C helper program for UTF-8 boundary testing (no Python dependency)

## 0.0.0

- Initial empty project

