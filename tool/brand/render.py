"""Render official Quantum branding. Requires resvg-py==0.5.0 and Pillow."""
from pathlib import Path
import io
import re
import resvg_py
from PIL import Image

HERE = Path(__file__).resolve().parent
RES = HERE.parents[1] / 'android/app/src/main/res'
official = (HERE / 'quantum-official.svg').read_text()
inner = official[official.index('>') + 1:official.rindex('</svg>')]
folders = re.sub(r'<circle[^>]*/>', '', inner)
masters = {
    'foreground': f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108"><g transform="translate(22 22) scale(2)">{inner}</g></svg>',
    'background': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108"><path fill="#141D24" d="M0 0h108v108H0z"/></svg>',
    'monochrome': f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108"><g transform="translate(22 22) scale(2)">{re.sub(r"#[A-Fa-f0-9]{6}", "#FFFFFF", folders)}</g></svg>',
    'legacy': official,
}
for layer, svg in masters.items():
    clean = '\n'.join(line.rstrip() for line in svg.splitlines()).strip() + '\n'
    (HERE / f'ic_launcher_{layer}.svg').write_text(clean)

def render(svg, pixels):
    return resvg_py.svg_to_bytes(svg_string=svg, width=pixels, height=pixels)

for dpi, scale in [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)]:
    mipmap = RES / f'mipmap-{dpi}'
    drawable = RES / f'drawable-{dpi}'
    mipmap.mkdir(exist_ok=True)
    drawable.mkdir(exist_ok=True)
    for layer in ('foreground', 'background', 'monochrome'):
        (mipmap / f'ic_launcher_{layer}.png').write_bytes(render(masters[layer], int(108 * scale)))
    (mipmap / 'ic_launcher.png').write_bytes(render(official, int(48 * scale)))
    (drawable / 'ic_splash.png').write_bytes(render(masters['foreground'], int(288 * scale)))
(HERE / 'ic_launcher_playstore_512.png').write_bytes(render(official, 512))
splash = Image.new('RGBA', (1080, 2340), '#141D24')
mark = Image.open(io.BytesIO(render(official, 512)))
splash.alpha_composite(mark, (284, 914))
splash.save(HERE / 'splash_fullscreen_1080x2340.png')
