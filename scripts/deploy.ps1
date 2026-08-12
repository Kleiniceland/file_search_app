<#
.SYNOPSIS
    Local Multimodal Semantic Search Engine - One-Click Deploy Script

.DESCRIPTION
    Completes the following deployment steps:
    1. Environment check (Flutter / Python / Visual Studio)
    2. Flutter dependency installation
    3. ObjectBox code generation
    4. Model weight download/generation
    5. Build verification
    6. Integration tests (optional)

.PARAMETER SkipModels
    Skip model download/generation step

.PARAMETER SkipTests
    Skip integration test step

.PARAMETER RunApp
    Launch the app after deployment

.EXAMPLE
    .\scripts\deploy.ps1
    .\scripts\deploy.ps1 -SkipModels
    .\scripts\deploy.ps1 -RunApp
#>

param(
    [switch]$SkipModels,
    [switch]$SkipTests,
    [switch]$RunApp
)

$ErrorActionPreference = "Continue"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $ProjectRoot

function Write-Step($msg) {
    Write-Host ""
    Write-Host "========== $msg ==========" -ForegroundColor Cyan
}

function Write-OK($msg) {
    Write-Host "  [OK] $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "  [WARN] $msg" -ForegroundColor Yellow
}

function Write-Err($msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
}

function Test-Command($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

# ============================================================
# Step 1: Environment Check
# ============================================================
Write-Step "Step 1/6: Environment Check"

# Flutter
if (-not (Test-Command "flutter")) {
    Write-Err "Flutter not installed. Download from https://flutter.dev and add to PATH"
    exit 1
}
$flutterVer = flutter --version 2>&1 | Select-Object -First 1
Write-OK "Flutter: $flutterVer"

# Dart
if (-not (Test-Command "dart")) {
    Write-Err "Dart not installed (should come with Flutter)"
    exit 1
}
Write-OK "Dart: installed"

# Visual Studio (C++ workload, required for desktop builds)
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vsWhere) {
    $vsPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>&1
    if ($vsPath) {
        Write-OK "Visual Studio: $vsPath"
    } else {
        Write-Warn "Visual Studio C++ workload not found (required for desktop builds)"
        Write-Warn "Install Visual Studio 2022 with 'Desktop development with C++'"
    }
} else {
    Write-Warn "vswhere not found, cannot verify Visual Studio installation"
}

# Python (only needed for model generation)
if (-not (Test-Command "python")) {
    Write-Warn "Python not installed (only needed for model generation)"
} else {
    $pyVer = python --version 2>&1
    Write-OK "Python: $pyVer"
}

Write-OK "Environment check complete"

# ============================================================
# Step 2: Flutter Dependency Installation
# ============================================================
Write-Step "Step 2/6: Flutter Dependency Installation"

Write-Host "  Running flutter pub get..."
flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Err "flutter pub get failed"
    exit 1
}
Write-OK "Dependencies installed"

# ============================================================
# Step 3: ObjectBox Code Generation
# ============================================================
Write-Step "Step 3/6: ObjectBox Code Generation"

Write-Host "  Running build_runner..."
dart run build_runner build --delete-conflicting-outputs
if ($LASTEXITCODE -ne 0) {
    Write-Err "ObjectBox code generation failed"
    exit 1
}
Write-OK "ObjectBox code generation complete"

# ============================================================
# Step 4: Model Weight Preparation
# ============================================================
if (-not $SkipModels) {
    Write-Step "Step 4/6: Model Weight Preparation"

    $BertDir = Join-Path $ProjectRoot "assets\models\bert_chinese_onnx"
    $MobileClipDir = Join-Path $ProjectRoot "assets\models\mobileclip_onnx"

    $BertModel = Join-Path $BertDir "model.onnx"
    $BertVocab = Join-Path $BertDir "vocab.txt"
    $ImageEncoder = Join-Path $MobileClipDir "image_encoder.onnx"
    $TextEncoder = Join-Path $MobileClipDir "text_encoder.onnx"
    $ClipVocab = Join-Path $MobileClipDir "clip_vocab.json"
    $ClipMerges = Join-Path $MobileClipDir "clip_merges.txt"
    $PreprocessConfig = Join-Path $MobileClipDir "preprocess_config.json"

    $missingModels = @()
    if (-not (Test-Path $BertModel)) { $missingModels += "BERT Chinese model" }
    if (-not (Test-Path $BertVocab)) { $missingModels += "BERT vocab" }
    if (-not (Test-Path $ImageEncoder)) { $missingModels += "MobileCLIP image encoder" }
    if (-not (Test-Path $TextEncoder)) { $missingModels += "MobileCLIP text encoder" }
    if (-not (Test-Path $ClipVocab)) { $missingModels += "CLIP vocab" }
    if (-not (Test-Path $ClipMerges)) { $missingModels += "CLIP merges" }
    if (-not (Test-Path $PreprocessConfig)) { $missingModels += "Preprocess config" }

    if ($missingModels.Count -eq 0) {
        Write-OK "All model files present"
    } else {
        Write-Host "  Missing models: $($missingModels -join ', ')"

        # Try download script
        $downloadScript = Join-Path $ProjectRoot "scripts\download_models.ps1"
        if (Test-Path $downloadScript) {
            Write-Host "  Running model download script..."
            & $downloadScript
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Model download script failed, trying Python scripts"

                if (Test-Command "python") {
                    # Generate BERT Chinese model
                    if (-not (Test-Path $BertModel)) {
                        Write-Host "  Generating BERT Chinese model..."
                        python scripts\export_bert_chinese_onnx.py
                    }

                    # Generate MobileCLIP model
                    if (-not (Test-Path $ImageEncoder) -or -not (Test-Path $TextEncoder)) {
                        Write-Host "  Generating MobileCLIP multimodal model..."
                        pip install torch onnx open_clip_torch transformers pillow onnxruntime 2>&1 | Out-Null
                        python scripts\export_mobileclip_multimodal.py
                    }
                } else {
                    Write-Err "Python not installed, cannot auto-generate models"
                    Write-Host "  Run scripts/download_models.ps1 manually"
                    Write-Host "  Or see docs/DEPLOYMENT.md for manual model preparation"
                    exit 1
                }
            }
        } else {
            Write-Err "Model download script not found: $downloadScript"
            exit 1
        }

        # Re-check
        $stillMissing = @()
        if (-not (Test-Path $BertModel)) { $stillMissing += "BERT Chinese model" }
        if (-not (Test-Path $ImageEncoder)) { $stillMissing += "MobileCLIP image encoder" }
        if (-not (Test-Path $TextEncoder)) { $stillMissing += "MobileCLIP text encoder" }

        if ($stillMissing.Count -gt 0) {
            Write-Err "Models still missing: $($stillMissing -join ', ')"
            Write-Host "  See docs/DEPLOYMENT.md for manual preparation"
            exit 1
        }
        Write-OK "Model preparation complete"
    }
} else {
    Write-Step "Step 4/6: Skip model preparation (-SkipModels)"
}

# ============================================================
# Step 5: Build Verification
# ============================================================
Write-Step "Step 5/6: Build Verification"

Write-Host "  Running flutter analyze..."
flutter analyze 2>&1 | Select-Object -Last 5
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Code analysis found issues (non-blocking)"
}

Write-Host "  Building Windows app..."
flutter build windows --debug 2>&1 | Select-Object -Last 3
if ($LASTEXITCODE -ne 0) {
    Write-Err "Build failed"
    exit 1
}
Write-OK "Build successful"

# ============================================================
# Step 6: Integration Tests
# ============================================================
if (-not $SkipTests) {
    Write-Step "Step 6/6: Integration Tests"

    $testFiles = @(
        "integration_test\cross_modal_search_test.dart",
        "integration_test\pipeline_e2e_test.dart",
        "integration_test\retrieval_benchmark_test.dart"
    )

    $allPassed = $true
    foreach ($testFile in $testFiles) {
        if (Test-Path (Join-Path $ProjectRoot $testFile)) {
            Write-Host "  Running $testFile..."
            flutter test $testFile -d windows 2>&1 | Select-Object -Last 3
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "$testFile failed"
                $allPassed = $false
            } else {
                Write-OK "$testFile passed"
            }
        }
    }

    if ($allPassed) {
        Write-OK "All integration tests passed"
    } else {
        Write-Warn "Some tests failed (non-blocking)"
    }
} else {
    Write-Step "Step 6/6: Skip tests (-SkipTests)"
}

# ============================================================
# Done
# ============================================================
Write-Step "Deployment Complete"

Write-Host ""
Write-Host "  Deployment successful! App is ready." -ForegroundColor Green
Write-Host ""
Write-Host "  Launch app: flutter run -d windows"
Write-Host "  Run tests:   flutter test integration_test/ -d windows"
Write-Host "  See docs:    docs/ directory"
Write-Host ""

if ($RunApp) {
    Write-Host "  Launching app..."
    flutter run -d windows
}
