# shared/crypto.ps1 - encrypt/decrypt helpers for claude-on-a-stick (Windows builder side)
#
# Dot-sourced by builders/windows/build.ps1. Provides the ENCRYPT side used at build time
# (write config\oauth.enc) plus a Decrypt wrapper that mirrors payload\decrypt.ps1 so the
# builder can self-test the round-trip before declaring success.
#
# IMPORTANT: this file MUST be saved as UTF-8 WITH BOM so Windows PowerShell 5.1 reads it
# correctly (matches the i18n contract). It is pure .NET - no openssl dependency on Windows.
#
# On-disk format (VERIFIED interoperable with openssl 3 / LibreSSL+perl / python):
#     oauth.enc = salt[16] || iv[16] || AES-256-CBC(PKCS7) ciphertext
# KDF: PBKDF2-HMAC-SHA1, 300000 iterations, 32-byte key.
#   .NET's Rfc2898DeriveBytes(string, byte[], int) 3-ARG ctor uses HMAC-SHA1 and UTF-8-encodes
#   the password. That is exactly what crypto.sh's python/openssl/perl paths do, so every
#   implementation derives the SAME 32 bytes (verified: keyhex identical across all four).

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# New-CasKey [string]$Password [byte[]]$Salt  ->  [byte[]] 32-byte key
# 3-arg Rfc2898DeriveBytes ctor == PBKDF2-HMAC-SHA1. Do NOT switch to the 4-arg
# (HashAlgorithmName) overload with SHA256 - that would break interop with openssl/python.
# ---------------------------------------------------------------------------
function New-CasKey {
  param(
    [Parameter(Mandatory = $true)][string] $Password,
    [Parameter(Mandatory = $true)][byte[]] $Salt
  )
  $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, 300000)
  try   { return $kdf.GetBytes(32) }
  finally { $kdf.Dispose() }
}

# ---------------------------------------------------------------------------
# Protect-CasToken [string]$Plaintext [string]$Password [string]$OutPath
# Generates fresh random salt+iv, AES-256-CBC/PKCS7 encrypts, writes salt|iv|ct to $OutPath.
# ---------------------------------------------------------------------------
function Protect-CasToken {
  param(
    [Parameter(Mandatory = $true)][string] $Plaintext,
    [Parameter(Mandatory = $true)][string] $Password,
    [Parameter(Mandatory = $true)][string] $OutPath
  )

  $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $salt = New-Object byte[] 16
  $iv   = New-Object byte[] 16
  $rng.GetBytes($salt)
  $rng.GetBytes($iv)

  $key = New-CasKey -Password $Password -Salt $salt

  $aes = [System.Security.Cryptography.Aes]::Create()
  try {
    $aes.KeySize = 256
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $key
    $aes.IV      = $iv

    $enc = $aes.CreateEncryptor()
    try {
      $ptBytes = [System.Text.Encoding]::UTF8.GetBytes($Plaintext)
      $ctBytes = $enc.TransformFinalBlock($ptBytes, 0, $ptBytes.Length)
    } finally { $enc.Dispose() }

    # Assemble salt || iv || ciphertext.
    $outBytes = New-Object byte[] (32 + $ctBytes.Length)
    [Array]::Copy($salt,    0, $outBytes, 0,  16)
    [Array]::Copy($iv,      0, $outBytes, 16, 16)
    [Array]::Copy($ctBytes, 0, $outBytes, 32, $ctBytes.Length)
    [System.IO.File]::WriteAllBytes($OutPath, $outBytes)
  } finally {
    $aes.Dispose()
    # Best-effort scrub of the key material from memory.
    if ($key) { for ($i = 0; $i -lt $key.Length; $i++) { $key[$i] = 0 } }
  }
}

# ---------------------------------------------------------------------------
# Unprotect-CasToken [string]$InPath [string]$Password  ->  [string] token
# Builder self-test helper (the stick uses payload\decrypt.ps1 standalone). Throws on failure
# (wrong password surfaces as a CryptographicException on TransformFinalBlock / bad padding).
# ---------------------------------------------------------------------------
function Unprotect-CasToken {
  param(
    [Parameter(Mandatory = $true)][string] $InPath,
    [Parameter(Mandatory = $true)][string] $Password
  )

  $all  = [System.IO.File]::ReadAllBytes($InPath)
  if ($all.Length -lt 33) { throw "oauth.enc too short (corrupt): $InPath" }

  [byte[]]$salt = $all[0..15]
  [byte[]]$iv   = $all[16..31]
  [byte[]]$ct   = $all[32..($all.Length - 1)]

  $key = New-CasKey -Password $Password -Salt $salt

  $aes = [System.Security.Cryptography.Aes]::Create()
  try {
    $aes.KeySize = 256
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $key
    $aes.IV      = $iv

    $dec = $aes.CreateDecryptor()
    try {
      $ptBytes = $dec.TransformFinalBlock($ct, 0, $ct.Length)
    } finally { $dec.Dispose() }

    return [System.Text.Encoding]::UTF8.GetString($ptBytes)
  } finally {
    $aes.Dispose()
    if ($key) { for ($i = 0; $i -lt $key.Length; $i++) { $key[$i] = 0 } }
  }
}
