$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot 'public'
$prefix = 'http://localhost:8765/'
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
Start-Process ($prefix + 'index.html')
Write-Host "Finlo is running at $prefix"
Write-Host "Close this window to stop Finlo."

$types = @{
  '.html'='text/html; charset=utf-8'; '.js'='application/javascript; charset=utf-8';
  '.css'='text/css; charset=utf-8'; '.json'='application/json; charset=utf-8';
  '.png'='image/png'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg';
  '.svg'='image/svg+xml'; '.ico'='image/x-icon'; '.txt'='text/plain; charset=utf-8'
}
try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      $relative = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
      if ([string]::IsNullOrWhiteSpace($relative)) { $relative = 'index.html' }
      $file = [IO.Path]::GetFullPath((Join-Path $root $relative))
      if (-not $file.StartsWith(([IO.Path]::GetFullPath($root) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $ctx.Response.StatusCode = 404
        $bytes = [Text.Encoding]::UTF8.GetBytes('Not found')
      } else {
        $bytes = [IO.File]::ReadAllBytes($file)
        $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($types.ContainsKey($ext)) { $ctx.Response.ContentType = $types[$ext] }
        $ctx.Response.StatusCode = 200
      }
      $ctx.Response.ContentLength64 = $bytes.Length
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
      $ctx.Response.StatusCode = 500
    } finally { $ctx.Response.Close() }
  }
} finally { $listener.Stop(); $listener.Close() }
