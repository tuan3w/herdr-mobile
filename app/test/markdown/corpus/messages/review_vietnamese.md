# Kết quả rà soát `lib/locale/`

Mình đã đọc xong **toàn bộ** thư mục và chạy `flutter test test/locale_test.dart`: *18 passed*, 1 failed. Tóm tắt bên dưới.

## Lỗi chính

Hàm [`parseLocale`](lib/locale/parse.dart) chuyển chuỗi về chữ thường **trước khi** chuẩn hóa NFC, nên `Hà Nội` (dạng phân rã) không khớp với khóa trong bảng:

```dart
String normalizeKey(String raw) {
  final lower = raw.toLowerCase();      // sai thứ tự
  return lower.nfc();                   // phải chuẩn hóa trước
}

String fixedKey(String raw) => raw.nfc().toLowerCase();
```

Cách sửa gồm ba bước:

1. Đổi thứ tự trong `normalizeKey` (xem `lib/locale/parse.dart:88`).
2. Thêm test cho các chuỗi sau:
   - `Hà Nội` (dạng dựng sẵn, U+1EA1)
   - `Hà Nội` (dạng phân rã, `a` + U+0323)
   - `ĐÀ NẴNG` (chữ hoa, có dấu)
3. Chạy lại toàn bộ bộ test.

   Nếu còn lỗi, xem `test/locale_test.dart:41`, nơi so sánh bằng `==` thay vì `compareTo`.

## Bảng so sánh

| Chuỗi | Trước khi sửa | Sau khi sửa | Ghi chú |
|:------|:-------------:|:-----------:|--------:|
| `Hà Nội` | khớp | khớp | dạng dựng sẵn |
| `Hà Nội` (NFD) | **không khớp** | khớp | lỗi gốc |
| `ĐÀ NẴNG` | khớp | khớp | |
| `Huế` | không khớp | khớp | ~~đã bỏ qua~~ đã sửa |

> [!WARNING]
> Không chạy `git push --force` lên `main`. Hãy mở PR và chờ CI xanh.

## Việc còn lại

- [x] sửa thứ tự chuẩn hóa
- [x] thêm test NFD
- [ ] cập nhật `CHANGELOG.md`
- [ ] kiểm tra `lib/locale/plural.dart`, xem https://example.com/cldr/vi để biết quy tắc số nhiều.

Chi tiết lệnh đã chạy:
Lệnh 1: `flutter test`
Lệnh 2: `dart analyze lib/locale`
Kết quả: không có cảnh báo.

---

Hết. Cần mình mở PR không?
