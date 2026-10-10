# Instalar VitaIRC en iPhone o iPad

Apple solo deja instalar apps de fuera de la App Store si están firmadas con **tu propio Apple ID**.
La versión publicada trae un `VitaIRC.ipa` sin firmar; una de estas herramientas lo firma con tu
cuenta y lo instala. Tu Apple ID y contraseña van solo a Apple.

| | Apple ID gratis | Cuenta de desarrollador de Apple (99 USD/año) |
|---|---|---|
| Cuánto dura la app | 7 días, luego hay que renovarla | 1 año |
| Renovación | AltStore/SideStore lo hacen solos | — |

## Opción A: AltStore (recomendada, se renueva sola)

1. En un Mac o PC instala **AltServer** desde <https://altstore.io> (en Mac queda en la barra de menú).
2. Conecta el iPhone con cable, confía en el computador y en AltServer elige
   **Install AltStore → tu iPhone**. Entra con tu Apple ID.
3. En el iPhone: **Ajustes → General → VPN y gestión de dispositivos →** tu Apple ID → **Confiar**.
   En iOS 16 o superior activa también **Ajustes → Privacidad y seguridad → Modo de desarrollador**
   (el iPhone se reinicia).
4. En el iPhone abre Safari, baja `VitaIRC.ipa` de la
   [última versión](https://github.com/ArchelKrozt/VitaIRC-iOS/releases/latest)
   y toca **Compartir → AltStore** (o en AltStore: **My Apps → +** y elige el archivo).
5. VitaIRC aparece en la pantalla de inicio. AltStore la renueva cada pocos días mientras el
   computador con AltServer esté en la misma red Wi-Fi (o abre AltStore y toca **Refresh All**).

**SideStore** (<https://sidestore.io>) funciona igual, pero después de la primera instalación se
renueva desde el propio iPhone, sin computador.

## Opción B: Sideloadly (simple, se renueva a mano cada 7 días)

1. Instala **Sideloadly** (<https://sideloadly.io>) en un Mac o PC y conecta el iPhone con cable.
2. Arrastra `VitaIRC.ipa` a Sideloadly, escribe tu Apple ID y pulsa **Start**.
3. En el iPhone: **Ajustes → General → VPN y gestión de dispositivos →** tu Apple ID → **Confiar**
   (y el Modo de desarrollador en iOS 16 o superior, como arriba).
4. A los 7 días la app deja de abrir: repite el paso 2 (tus ajustes e historial se conservan).

## Opción C: Xcode (para desarrolladores)

```sh
brew install xcodegen
xcodegen generate
open VitaIRC.xcodeproj
```

En Xcode elige tu equipo en **Signing & Capabilities**, conecta el iPhone y pulsa **Run**.

## Actualizaciones

VitaIRC revisa GitHub una vez al día y te avisa cuando hay una versión nueva. iOS no le permite
instalarla sola: baja el nuevo `VitaIRC.ipa` e instálalo igual que la primera vez (AltStore: **+**;
Sideloadly: arrástralo de nuevo). Se instala encima y conserva servidores, ajustes e historial.

## Tus ajustes y la Vita

Los archivos de VitaIRC están en la app **Archivos → En mi iPhone → VitaIRC**: `config.ini` (el
mismo archivo de la Vita y Android: copia el tuyo ahí para traer tus servidores), los historiales y
tus favoritos.
