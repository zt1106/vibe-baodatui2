## Zig Version
- Current project using the Zig version 0.15.2, please make sure the version is correct when searching documents

## Build Instructions
- Run `zig build` in backend folder to compile the backend server

## Test Instructions
- Run `zig build test` to compile and run all tests in backend folder
- Don't run `zig test xxx.zig` to execute test because it won't work

## Unit Tests & Integration Tests
- Unit tests are normal Zig unique tests
- Integration tests in this project looks like unit tests, but they utilize the test client to actually launch and connect a real game server, so they test both logic and communications.
    - Integration tests are located in ./backend/src/integration_tests folder