# pdf/voice

Senkronize kelime vurgulama özelliğine sahip, sade ve yerel bir macOS PDF seslendirme uygulaması.

![pdf/voice uygulama ekran görüntüsü](docs/ss.png)

*Ekran görüntüsü önceki sürümün arayüzünü gösterir.*

## Özellikler

- PDF seçme, sürükleyip bırakma ve Finder’dan **Birlikte Aç** desteği
- PDF ve metin görünümü; italik metinde okunan kelimeyi kalın italik vurgulama
- Kelimeye çift tıklayarak veya **Buradan Oku** ile seçilen konumdan başlatma
- Duraklatma, sürdürme ve sayfalar arasında otomatik ilerleme
- Dil ve sistem sesi seçimi, konuşma hızı ve ses tonu ayarları
- Son belgeler, kelime düzeyinde okuma konumu, belge araması ve yer imleri
- Apple Vision ile otomatik veya elle OCR ve kalıcı OCR önbelleği
- İsteğe bağlı satır sonu, sayfa numarası ve tekrarlanan kenar metni temizliği
- Uyku zamanlayıcısı ve sayfayı/belgeyi AIFF ses dosyası olarak dışa aktarma
- Açık ve koyu görünüm desteği


## Çalıştırma

```bash
zsh scripts/build.sh
open "dist/PDF to Voice.app"
```

## Kullanılan Teknolojiler

Swift, SwiftUI, AppKit, PDFKit, AVFoundation ve Vision. Üçüncü taraf bağımlılık kullanılmaz.

## Bilinen Sınırlamalar

- OCR metni, görüntüden çıkarılan okuma sırasına bağlıdır; çok sütunlu sayfalar elle kontrol edilmelidir.
- OCR ile okunan taramalarda PDF üzerinde kelime vurgusu yoktur; metin görünümünde vurgu çalışır.
- Ses hızındaki çarpan, yaklaşık bir arayüz göstergesidir.
- İmzasız/yerel imzalı paketler başka Mac’lerde Gatekeeper kontrolüne takılabilir.

## Kullanım notları

OCR ve seslendirme sistem araçlarıyla yerel olarak çalışır. İhtiyaç duyulan ek sistem sesleri macOS ayarlarından indirilebilir. Metin temizliği sayısal içeriği etkileyebileceğinden tablolarda kapatılabilir. Temizlik değiştirildiğinde o sayfadaki kelime konumu sıfırlanır. Son belge kaydı URL’ye bağlıdır; taşınan dosya yeni konumdan açıldığında yeni belge gibi takip edilir. Eski sürüm geçmişi kelime konumu içermediğinden dosyayı yeniden seçmek gerekebilir.

### Kontroller

```bash
zsh scripts/test.sh
zsh scripts/build.sh
open "dist/PDF to Voice.app"
```

Build scripti varsayılan olarak Apple Silicon ve Intel için evrensel uygulama ve ZIP üretir. Yalnızca mevcut mimari için `ARCHS=arm64 zsh scripts/build.sh` kullanılabilir. GitHub Actions her push/PR için regresyon kontrollerini ve evrensel derlemeyi çalıştırır; ZIP’i artifact olarak sunar.

### İmzalı dağıtım

Apple Developer hesabında hazırlanmış Developer ID sertifikası ve `notarytool` keychain profili gerekir. Kimlik bilgilerini repoya eklemeyin.

```bash
SIGNING_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
NOTARY_PROFILE="pdf-voice-notary" zsh scripts/build.sh
```

Bu değişkenlerle script hardened runtime imzası, notarization ve stapling uygular. Değişkenler olmadan yalnızca yerel kullanım için ad-hoc imza kullanılır. Xcode projesi ve script aynı Info.plist dosyasını kullanır.

İkonu yeniden üretmek için:

```bash
xcrun swift scripts/make-icon.swift PDFToVoice/Assets.xcassets/AppIcon.appiconset
```

Ses dışa aktarma macOS uygulaması içinde doğrulanır; `scripts/test.sh` ses aygıtı gerektirmeyen model regresyonlarını çalıştırır.

## Katkıda bulunma

Değişiklikten sonra `zsh scripts/test.sh` ve `zsh scripts/build.sh` komutlarını çalıştırın.
Seslendirme, ses dışa aktarma, OCR ve arayüz davranışlarını uygulamayı açarak da kontrol edin.
Derleme çıktıları `dist/` altında üretilir ve Git’e eklenmez. Xcode kullanıcı ayarları,
yerel ortam dosyaları ve imzalama anahtarları da repoya dahil edilmez.

## Lisans

[MIT](LICENSE)
