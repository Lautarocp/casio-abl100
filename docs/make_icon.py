# Genera el icono de la app (AppIcon-1024.png en el directorio actual). Requiere Pillow.
# Copiar el resultado a CasioABL100/CasioABL100/Assets.xcassets/AppIcon.appiconset/.
from PIL import Image, ImageDraw

S = 4                      # supersampling
W = 1024 * S
def p(*v): return [x * S for x in v]

BG      = (10, 10, 12)
STRAP   = (28, 28, 30)
CASE    = (44, 44, 46)
FACE    = (20, 20, 22)
ORANGE  = (255, 159, 10)   # systemOrange (modo oscuro)
LCD     = (150, 160, 150)
SEG     = (30, 36, 33)
BUTTON  = (90, 90, 94)

img = Image.new("RGB", (W, W), BG)
d = ImageDraw.Draw(img)

# Correas: trapecios arriba y abajo
d.polygon(p(330, 0, 694, 0, 724, 190, 300, 190), fill=STRAP)
d.polygon(p(300, 834, 724, 834, 694, 1024, 330, 1024), fill=STRAP)

# Botones laterales (izquierda: luz y modo; derecha: alarma)
d.rounded_rectangle(p(160, 400, 200, 440), radius=6 * S, fill=BUTTON)
d.rounded_rectangle(p(160, 600, 200, 640), radius=6 * S, fill=BUTTON)
d.rounded_rectangle(p(824, 600, 864, 640), radius=6 * S, fill=BUTTON)

# Caja octogonal
c = 110
d.polygon(p(190 + c, 160, 834 - c, 160, 834, 160 + c, 834, 864 - c,
            834 - c, 864, 190 + c, 864, 190, 864 - c, 190, 160 + c), fill=CASE)

# Esfera con la línea de acento naranja (el azul del F-91W)
d.rounded_rectangle(p(248, 262, 776, 762), radius=70 * S, fill=FACE)
d.rounded_rectangle(p(248, 262, 776, 762), radius=70 * S, outline=ORANGE, width=12 * S)

# Pantalla LCD
d.rounded_rectangle(p(296, 360, 728, 664), radius=34 * S, fill=LCD)

# Dígitos de 7 segmentos: "12:00"
DW, DH, T = 86, 190, 20        # ancho, alto y grosor del segmento
def segments(x, y):
    h, g = T / 2, 5            # medio grosor y separación entre segmentos
    mid = y + DH / 2
    def hseg(yc):  # horizontal con puntas biseladas
        return [x + g, yc, x + g + h, yc - h, x + DW - g - h, yc - h, x + DW - g, yc,
                x + DW - g - h, yc + h, x + g + h, yc + h]
    def vseg(xc, y0, y1):
        return [xc, y0 + g, xc + h, y0 + g + h, xc + h, y1 - g - h, xc, y1 - g,
                xc - h, y1 - g - h, xc - h, y0 + g + h]
    return {
        "a": hseg(y + h), "g": hseg(mid), "d": hseg(y + DH - h),
        "f": vseg(x + h, y, mid), "b": vseg(x + DW - h, y, mid),
        "e": vseg(x + h, mid, y + DH), "c": vseg(x + DW - h, mid, y + DH),
    }

DIGITS = {"0": "abcdef", "1": "bc", "2": "abged"}
def digit(ch, x, y):
    segs = segments(x, y)
    for s in DIGITS[ch]:
        d.polygon(p(*segs[s]), fill=SEG)

top = 417
# El "1" solo usa la columna derecha: se centra lo visible (de su segmento hasta el último dígito)
digit("1", 268, top)
digit("2", 368, top)
for cy in (top + 57, top + 133):                     # dos puntos
    d.rectangle(p(468, cy - 10, 488, cy + 10), fill=SEG)
digit("0", 504, top)
digit("0", 604, top)

img = img.resize((1024, 1024), Image.LANCZOS)
img.save("AppIcon-1024.png")
img.resize((180, 180), Image.LANCZOS).save("preview-180.png")
print("ok")
