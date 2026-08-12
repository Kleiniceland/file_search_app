<#
.SYNOPSIS
    Download/generate all model weights required by this project

.DESCRIPTION
    This script prepares the following model files:
    - BERT Chinese model (uer/chinese_roberta_L-6_H-512 -> ONNX)
    - MobileCLIP-S1 image encoder (open_clip -> ONNX)
    - MobileCLIP-S1 text encoder (open_clip -> ONNX)
    - CLIP tokenizer (vocab.json + merges.txt)
    - Preprocess config (preprocess_config.json)

    Strategy: Check local cache first -> Generate via Python scripts
    Generation requires Python 3.11+ and torch/onnx/open_clip_torch/transformers

.EXAMPLE
    .\scripts\download_models.ps1
#>

$ErrorActionPreference = "Continue"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $ProjectRoot

function Write-Step($msg) {
    Write-Host ""
    Write-Host "===== $msg =====" -ForegroundColor Cyan
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

# ============================================================
# Check Python
# ============================================================
Write-Step "Checking Python environment"

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Err "Python not installed"
    Write-Host "  Install Python 3.11+ from https://python.org"
    Write-Host "  Or download model files manually from HuggingFace"
    exit 1
}

$pyVer = python --version 2>&1
Write-OK "Python: $pyVer"

# ============================================================
# Prepare directories
# ============================================================
Write-Step "Preparing directory structure"

$BertDir = Join-Path $ProjectRoot "assets\models\bert_chinese_onnx"
$MobileClipDir = Join-Path $ProjectRoot "assets\models\mobileclip_onnx"

New-Item -ItemType Directory -Force -Path $BertDir | Out-Null
New-Item -ItemType Directory -Force -Path $MobileClipDir | Out-Null

Write-OK "Directories ready"

# ============================================================
# Check existing models
# ============================================================
Write-Step "Checking existing model files"

$BertModel = Join-Path $BertDir "model.onnx"
$BertVocab = Join-Path $BertDir "vocab.txt"
$BertConfig = Join-Path $BertDir "config.json"
$ImageEncoder = Join-Path $MobileClipDir "image_encoder.onnx"
$TextEncoder = Join-Path $MobileClipDir "text_encoder.onnx"
$ClipVocab = Join-Path $MobileClipDir "clip_vocab.json"
$ClipMerges = Join-Path $MobileClipDir "clip_merges.txt"
$PreprocessConfig = Join-Path $MobileClipDir "preprocess_config.json"

$existingFiles = @()
if (Test-Path $BertModel) { $existingFiles += "BERT model.onnx" }
if (Test-Path $BertVocab) { $existingFiles += "BERT vocab.txt" }
if (Test-Path $BertConfig) { $existingFiles += "BERT config.json" }
if (Test-Path $ImageEncoder) { $existingFiles += "MobileCLIP image_encoder.onnx" }
if (Test-Path $TextEncoder) { $existingFiles += "MobileCLIP text_encoder.onnx" }
if (Test-Path $ClipVocab) { $existingFiles += "CLIP vocab.json" }
if (Test-Path $ClipMerges) { $existingFiles += "CLIP merges.txt" }
if (Test-Path $PreprocessConfig) { $existingFiles += "preprocess_config.json" }

if ($existingFiles.Count -gt 0) {
    Write-OK "Existing files:"
    foreach ($f in $existingFiles) {
        Write-Host "    - $f"
    }
}

# ============================================================
# Install Python dependencies
# ============================================================
Write-Step "Installing Python dependencies"

Write-Host "  Installing torch / onnx / optimum / transformers / open_clip_torch..."
pip install --quiet torch onnx optimum[onnxruntime] transformers open_clip_torch pillow 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Warn "Some dependencies failed to install, continuing anyway"
} else {
    Write-OK "Python dependencies installed"
}

# Set HuggingFace mirror (for China users)
$env:HF_ENDPOINT = "https://hf-mirror.com"
Write-Host "  Using HuggingFace mirror: $env:HF_ENDPOINT"

# ============================================================
# Generate BERT Chinese model
# ============================================================
if (-not (Test-Path $BertModel) -or -not (Test-Path $BertVocab)) {
    Write-Step "Generating BERT Chinese model (uer/chinese_roberta_L-6_H-512)"

    $script = Join-Path $ProjectRoot "scripts\export_bert_chinese_onnx.py"
    if (Test-Path $script) {
        Write-Host "  Running export_bert_chinese_onnx.py ..."
        python $script
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "BERT export script failed"
            Write-Host "  Download manually from https://huggingface.co/uer/chinese_roberta_L-6_H-512"
        } else {
            Write-OK "BERT Chinese model generated"
        }
    } else {
        Write-Err "BERT export script not found: $script"
    }
} else {
    Write-OK "BERT Chinese model already exists, skipping"
}

# ============================================================
# Generate MobileCLIP multimodal model
# ============================================================
$needMobileClip = $false
if (-not (Test-Path $ImageEncoder)) { $needMobileClip = $true }
if (-not (Test-Path $TextEncoder)) { $needMobileClip = $true }
if (-not (Test-Path $ClipVocab)) { $needMobileClip = $true }
if (-not (Test-Path $ClipMerges)) { $needMobileClip = $true }
if (-not (Test-Path $PreprocessConfig)) { $needMobileClip = $true }

if ($needMobileClip) {
    Write-Step "Generating MobileCLIP multimodal model (MobileCLIP-S1)"

    $script = Join-Path $ProjectRoot "scripts\export_mobileclip_multimodal.py"
    if (Test-Path $script) {
        Write-Host "  Running export_mobileclip_multimodal.py..."
        Write-Host "  First run downloads weights from HuggingFace (~300 MB)"
        python $script
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "MobileCLIP export script failed"
            Write-Host "  Get weights from https://github.com/apple/ml-mobileclip"
        } else {
            Write-OK "MobileCLIP model generated"
        }
    } else {
        Write-Err "MobileCLIP export script not found: $script"
    }
} else {
    Write-OK "MobileCLIP model already exists, skipping"
}

# ============================================================
# Final verification
# ============================================================
Write-Step "Verifying model files"

$requiredFiles = @{
    "BERT Chinese model" = $BertModel
    "BERT vocab" = $BertVocab
    "MobileCLIP image encoder" = $ImageEncoder
    "MobileCLIP text encoder" = $TextEncoder
    "CLIP vocab" = $ClipVocab
    "CLIP merges" = $ClipMerges
    "Preprocess config" = $PreprocessConfig
}

$allPresent = $true
foreach ($entry in $requiredFiles.GetEnumerator()) {
    if (Test-Path $entry.Value) {
        $size = (Get-Item $entry.Value).Length / 1MB
        Write-OK "$($entry.Key): $($size.ToString('F1')) MB"
    } else {
        Write-Err "$($entry.Key): MISSING"
        $allPresent = $false
    }
}

if ($allPresent) {
    Write-Host ""
    Write-Host "===== All model files ready =====" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Total model size: ~361 MB"
    Write-Host "  Now run: flutter run -d windows"
} else {
    Write-Host ""
    Write-Host "===== Some model files missing =====" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  See docs/DEPLOYMENT.md for manual preparation"
    Write-Host "  Or re-run this script"
    exit 1
}
