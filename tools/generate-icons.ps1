$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$flutterRoot = Split-Path -Parent (Split-Path -Parent (Get-Command flutter -ErrorAction Stop).Source)
$fontPath = Join-Path $flutterRoot 'bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf'
$fonts = New-Object Drawing.Text.PrivateFontCollection
$fonts.AddFontFile($fontPath)
# Same Material glyph and proportions as LineMark in lib/ui/brand.dart.
$symbol = [char]::ConvertFromUtf32(0xf01fa) # swap_horiz_rounded
function Get-IconPng([int]$size) {
    $renderSize = $size * 4
    $bitmap = New-Object Drawing.Bitmap($renderSize, $renderSize)
    $g = [Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $radius = [single]($renderSize * 0.5)
    $extent = [single]($renderSize - 1)
    $path.AddArc(0,0,$radius,$radius,180,90)
    $path.AddArc(($extent-$radius),0,$radius,$radius,270,90)
    $path.AddArc(($extent-$radius),($extent-$radius),$radius,$radius,0,90)
    $path.AddArc(0,($extent-$radius),$radius,$radius,90,90)
    $path.CloseFigure()
    $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(36,34,32))
    $g.FillPath($brush,$path)
    $glyph = New-Object Drawing.Drawing2D.GraphicsPath
    $glyph.AddString($symbol, $fonts.Families[0], 0, [single]($renderSize * .64), (New-Object Drawing.PointF(0,0)), [Drawing.StringFormat]::GenericTypographic)
    $bounds = $glyph.GetBounds()
    $transform = New-Object Drawing.Drawing2D.Matrix
    $transform.Translate([single](($renderSize-$bounds.Width)/2-$bounds.X), [single](($renderSize-$bounds.Height)/2-$bounds.Y))
    $glyph.Transform($transform)
    $g.FillPath([Drawing.Brushes]::White, $glyph)
    $result = New-Object Drawing.Bitmap($size, $size)
    $output = [Drawing.Graphics]::FromImage($result)
    $output.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $output.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $output.DrawImage($bitmap, (New-Object Drawing.Rectangle(0,0,$size,$size)))
    $stream = New-Object IO.MemoryStream
    $result.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
    $bytes = $stream.ToArray()
    $stream.Dispose(); $g.Dispose(); $bitmap.Dispose(); $path.Dispose(); $brush.Dispose()
    $glyph.Dispose(); $transform.Dispose(); $output.Dispose(); $result.Dispose()
    return ,$bytes
}
[IO.File]::WriteAllBytes((Join-Path $root 'assets\brand\line-icon.png'),(Get-IconPng 512))
$densities = @{ mdpi=48; hdpi=72; xhdpi=96; xxhdpi=144; xxxhdpi=192 }
foreach ($density in $densities.Keys) {
    $target = Join-Path $root "android\app\src\main\res\mipmap-$density\ic_launcher.png"
    [IO.File]::WriteAllBytes($target,(Get-IconPng $densities[$density]))
}
$sizes = @(16,24,32,48,64,128,256)
$images = @($sizes | ForEach-Object { ,(Get-IconPng $_) })
$icoPath = Join-Path $root 'windows\runner\resources\app_icon.ico'
$file = [IO.File]::Create($icoPath)
$writer = New-Object IO.BinaryWriter($file)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16*$sizes.Count
for ($i=0; $i -lt $sizes.Count; $i++) {
    $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
    $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
    $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($bytes in $images) { $writer.Write([byte[]]$bytes) }
$writer.Dispose(); $file.Dispose()

$fonts.Dispose()
