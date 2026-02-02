# Zig 0.14.x to 0.15.x Migration Protocol

## 1. Context and Objective

**Goal:** Transition Zig codebase from version 0.14.x compatibility to 0.15.x.
**Target Version:** Zig 0.15.0 (or latest 0.15.2).
**Primary Constraint:** Zig is pre-1.0; breaking changes are expected in the standard library (`std`), build system (`std.Build`), and language syntax.

## 2. Pre-Migration Analysis

Before modifying code, perform the following:
1.  **Version Verification:** Confirm the compiler version in the environment:
    ```bash
    zig version
    ```
    *Requirement:* Output must match `0.15.x`.
2.  **Clean Build:** Ensure the project builds cleanly on `0.14.x` before attempting upgrade to isolate version-specific errors.
3.  **Dependency Audit:** Review `build.zig.zon`. External dependencies must be updated to commits/tags compatible with 0.15.x.

## 3. Migration Heuristics

### 3.1. Build System (`build.zig`)
The `std.Build` API is frequently refactored.
* **Action:** specific attention to `b.addExecutable`, `b.addLibrary`, and module dependency injection.
* **Resolution Strategy:**
    * Compare `std.Build` method signatures against the source definition in `lib/std/Build.zig` of the 0.15.x compiler installation.
    * Check for deprecation of `b.standardTargetOptions` or `b.standardOptimizeOption` variants.
    * Verify `lazyDependency` implementations in `build.zig.zon` handling.

### 3.2. Standard Library (`std`)

* **Namespace Shifts:** Monitor `std.os` vs `std.posix` or platform-specific definitions.
* **Allocator Interface:** Check for changes in `std.mem.Allocator` vtable layout or `alloc`/`free` signatures.
* **Format String Compliance:** Validate `std.fmt` usage. Stricter compile-time checks often reject previously valid format strings (e.g., unused arguments, type mismatches).

### 3.3. Syntax and Semantics

* **`@import`:** Ensure strict file paths.
* **Pointer Casting:** Zig 0.15.x may enforce stricter pointer alignment and casting rules (e.g., `@ptrCast`, `@alignCast`). Validate all `@intToPtr` or `@ptrToInt` replacements if legacy syntax persists.
* **Result Location semantics:** Analyze RLS (Result Location Semantics) usage if return types or struct initialization logic changes.

## 4. Execution Protocol

### Step 1: Update Dependency Hashes

Invalidate old hashes to force fetch of new compatible dependencies.

```bash
zig build fetch --save

```

*If fetch fails due to protocol changes:* Manually verify URLs in `build.zig.zon`.

### Step 2: Compiler-Driven Refactoring (The "Fix-It" Loop)

Execute the build iteratively to identify and resolve breaking changes.

1. Run `zig build`.
2. Capture the **first** error output (cascading errors are often noise).
3. Categorize error:
* **Syntax Error:** Apply syntax fix (e.g., keyword changes).
* **Missing Member:** Check `std` docs for renames (e.g., `std.fs.path` functions).
* **Type Mismatch:** Insert explicit casts (`@as`, `@cast`) only where logically sound.

4. Repeat until compilation succeeds.

### Step 3: Autofix (If Available)

Attempt to use the built-in translation tool for known deprecations.

```bash
zig fmt .
```

### Step 4: Test Suite Validation

Compilation does not guarantee correctness.

```bash
zig build test
```

*Pass Criteria:* All tests pass with no memory leaks (`GeneralPurposeAllocator` typically detects these).

## 5. Known 0.15.x Patterns (Dynamic)

*Agents must update this section based on specific release notes found in `doc/langref.html` of the installed version.*

* **Pattern A:** [Placeholder for specific API rename]
* **Pattern B:** [Placeholder for build.zig artifact handling change]

## 6. Verification

Final validation requires a clean build and test pass in a fresh environment/container to ensure no cached artifacts mask issues.

```bash
zig build -Doptimize=ReleaseSafe
```
