#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="${PENCILCAD_TEST_BUILD_DIR:-$PWD/.build/core-tests}"
mkdir -p "$build_dir"
sources=(
  App/Model/Expressions.swift
  App/Model/ProjectUnits.swift
  App/Model/ExtrusionSpan.swift
  App/Model/MeshFileReader.swift
  App/Model/SketchGeometry.swift
  App/Model/SketchTextDeform.swift
  App/Model/SketchTextTransformGeometry.swift
  App/Model/SketchSplineInterpolation.swift
  App/Model/SketchTrim.swift
  App/Model/SketchArrangement.swift
  App/Model/SketchConstraints.swift
  App/Model/SketchLocalSolver.swift
)
swiftc -module-cache-path "$build_dir/ModuleCache" "${sources[@]}" Tests/CoreTests.swift -o "$build_dir/CoreTests"
"$build_dir/CoreTests"
