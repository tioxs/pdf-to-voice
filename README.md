# 📖 pdf/voice

PDF’lerini dinle, kaldığın kelimeden devam et. macOS için sade, yerel bir sesli okuma uygulaması.

![Uygulamanın önceki sürümünden görünüm](docs/ss.png)

## ✨ Özellikler

- PDF ve metin görünümü, okunan kelimeyi vurgulama
- Kelimeye çift tıklayarak okuma, duraklatma ve devam etme
- Ses seçimi, hız ve ton ayarları
- Kaldığın yeri hatırlama, arama ve yer imleri
- Taranmış sayfalar için OCR
- Uyku zamanlayıcısı ve AIFF ses dışa aktarma

## 🚀 Çalıştır

```bash
zsh scripts/build.sh
open "dist/PDF to Voice.app"
```

Apple Silicon ve Intel için evrensel paket `dist/` klasöründe oluşur.

## 🛠 Geliştirme

Swift ve SwiftUI ile geliştirildi. Üçüncü taraf bağımlılık yok.

```bash
zsh scripts/test.sh
```

## 📄 Lisans

[MIT](LICENSE)
