# C imports and cross compilation

## Header discovery

The generator translates `@cImport` include blocks and resolves translated C
types used by exported Zig declarations. Header discovery checks the source
file's directory, its `include/` subdirectory, and a sibling `include/`
directory. Configure include paths and libc linkage in `build.zig` separately
for the native build, as shown in [the cImport example](../example/cimport).

## Libc configuration

C translation checks `@import("builtin").link_libc` at compile time using the
selected library module's configuration from `build.zig`. This evaluates computed
build settings and does not execute target code, so it also works for cross
compilation. Use `--link-libc` or `--no-link-libc` (`ZigBindingsOptions.linkLibc`
in Dart) to override detection and skip the probe. Without `build.zig`, libc
support defaults to disabled. Keep overrides aligned with your native build.

The probe uses the build script's default options, plus the generator's target
and sysroot. Custom `ZigBuilder.extraArguments` are not passed to the probe.
If a custom build option changes libc linkage, set the generator override to
match that build.

## Cross compilation and sysroot

For target-dependent C headers, pass the same target ABI and appropriate system
root used by your native build:

```bash
dart run native_toolchain_zig:zig bindings \
  --package-root example/cimport \
  --zig-dir zig \
  --root-source-file src/lib.zig \
  --output lib/ffi.g.dart \
  --target aarch64-linux-gnu \
  --sysroot /path/to/target/sysroot
```

Replace the sysroot placeholder with an installed target sysroot, or omit
`--sysroot` if one is not needed. These options configure C translation during
binding generation. The build hook selects its compilation target from Dart's
build configuration. Regenerate target-dependent bindings when changing ABI.

## Generate and run the example

From the repository root:

```bash
dart run native_toolchain_zig:zig bindings \
  --package-root example/cimport \
  --output lib/ffi.g.dart
```

Then run `dart run cimport:main` from `example/cimport`.
The [Zig source](../example/cimport/zig/src/lib.zig),
[headers](../example/cimport/zig/include), and
[build script](../example/cimport/zig/build.zig) form a complete example.
The build script configures its own include paths and libc linkage; translation
settings do not replace native build configuration.

## Types and callbacks

The example covers C structs, unions, enums, arrays, pointer chains, and function
pointer callbacks. The generator emits declarations reachable from exported
Zig functions and globals; it does not expose every declaration in a header.
Fixed-size arrays include their sentinel storage when present.

Zig callback types must declare `callconv(.c)`. The generated native function
typedefs can be used with Dart's `NativeCallable` APIs. Keep callback objects and
any memory accessed by them alive while native code can use them, and close the
callbacks when finished. The [Dart wrapper](../example/cimport/lib/cimport.dart)
shows synchronous callbacks and asynchronous listeners with cleanup.

Zig `packed struct` types are rejected because their backing-integer ABI is not
preserved by Dart FFI packed structs. Use an `extern struct` for the exported
interface. Ambiguous type names fail generation instead of selecting a layout.
This source extractor supports include blocks and local literal Zig imports;
it does not evaluate arbitrary Zig code or resolve package-name imports.

## Generated files and watch mode

The extractor creates `.zigchain_cimport_source.c` and `.zigchain_cimport.zig`
next to the importing source. These are intermediate files, not maintained
source. Keep them out of version control. Temporary `.zigchain_probe_*` build
wrappers are removed after the libc check.

`--watch` follows files inside the Zig project directory, including local C
headers. It ignores generator output, intermediate files, and Zig caches.
Changes to external headers or SDK files require explicit regeneration.

## Troubleshooting

| Problem | Check |
| --- | --- |
| Local header not found | Put the header under a discovered include directory and configure the native build's include path too. |
| Standard header such as `assert.h` not found | Check libc detection and any override; for another target, check the SDK/sysroot. |
| Libc configuration cannot be determined | Ensure the selected source belongs to a build artifact. For conflicting configurations, use `--link-libc` or `--no-link-libc` to select the intended setting. |
| Native asset cannot be found at runtime | Match the generated asset ID to the build hook's `assetName`. |
| Binding layout changes with the target | Regenerate for that target ABI before building the application. |

See the [README](../README.md) for installation, build-hook setup, and the full
CLI reference.
