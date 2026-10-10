# Dürücü

Finder'da zip'e tıklayınca otomatik açılmasın; önce içine bak, istediğini çıkart. Dosyaları tek hamlede "dür".

*A native macOS archive app: browse ZIP/7Z/RAR/TAR before extracting, extract what you need, add or remove files, create archives.*

## Kurulum

```sh
brew install --cask falconsw/tap/durucu
```

İlk açılışta Dürücü kendini arşiv dosyaları için varsayılan uygulama yapar. Böylece Finder'da çift tıklayınca
Arşiv İzlencesi yerine Dürücü açılır. Geri almak için: bir zip'e sağ tık › Bilgi Al › Birlikte aç › Arşiv İzlencesi › Tümünü Değiştir.

## Özellikler

- **Aç:** ZIP, 7Z, RAR/RAR5, TAR, TAR.GZ/XZ/BZ2, GZ, XZ, ISO, CPIO
- **Gör:** klasör ağacı, sıralanabilir liste, arama, sıkıştırma kazancı, Hızlı Bakış (Boşluk), bilgi panelinde önizleme
- **Çıkart:** tümünü veya seçilenleri; akıllı klasör, çakışmada "ad 2", Finder'a sürükle-bırak
- **Düzenle:** arşive dosya/klasör ekle (sürükle-bırak veya ⇧⌘A), seçilenleri sil (⌘⌫). ZIP, 7Z ve TAR türlerinde çalışır; önceki sürüm Çöp Sepeti'ne gider
- **Dür:** ZIP (AES-256 şifre), 7Z, TAR.GZ, TAR.XZ; macOS artıklarını (.DS_Store, `._`, `__MACOSX`) dışarıda bırakır
- Windows'tan gelen Türkçe adlı zip'leri (CP857) doğru gösterir
- Finder sağ tık: **Dürücü ile Dür** ve **Dürücü ile Buraya Çıkart**

## Kaynaktan derleme

Gerekenler: Xcode 26+, macOS 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate          # Durucu.xcodeproj'u project.yml'den üretir
open Durucu.xcodeproj
./scripts/install.sh       # Release derleyip /Applications/Durucu.app'e kurar
./scripts/release.sh       # Developer ID ile imzalı, noter onaylı dağıtım paketi (dist/)
```

İkon `scripts/make-icon.swift` ile çizilir:
`swift scripts/make-icon.swift Durucu/Resources/Assets.xcassets/AppIcon.appiconset`

## Yapı

| Klasör | İçerik |
| --- | --- |
| `Durucu/Engine` | libarchive köprüsü (`CLibArchive`), okuma/çıkartma, arşiv yazma, ZIP merkez dizini |
| `Durucu/Models` | Pencere modelleri, arşiv ağacı, çıkartma servisi, önizleme önbelleği |
| `Durucu/Views` | SwiftUI ekranları (karşılama, tarayıcı, yeni arşiv, ayarlar) |
| `Durucu/App` | Uygulama yaşam döngüsü, pencere yönetimi, Finder servisleri |

Arşiv motoru macOS'un kendi `libarchive`'ını kullanır. SDK'da başlık dosyası olmadığı için gereken
fonksiyonlar `Engine/CLibArchive/libarchive_shim.h` içinde bildirilmiştir.

Debug derlemesinde `open --env DURUCU_SNAPSHOT_DIR=/klasör -a Durucu.app` her pencerenin görüntüsünü
o klasöre yazar (ekran kaydı izni gerektirmez).
