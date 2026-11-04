import 'package:fire_app/database/ndvi_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NDVIService.formatarDataModis', () {
    test('usa ano + dia do ano com 3 dígitos', () {
      expect(
        NDVIService.formatarDataModis(DateTime.utc(2026, 1, 1)),
        'A2026001',
      );
      expect(
        NDVIService.formatarDataModis(DateTime.utc(2026, 9, 14)),
        'A2026257',
      );
    });
  });

  group('NDVIService.extrairNDVIMaisRecente', () {
    test('retorna a composição mais recente aplicando a escala', () {
      final resposta = {
        'scale': '0.0001',
        'subset': [
          {
            'modis_date': 'A2026241',
            'data': [2042],
          },
          {
            'modis_date': 'A2026257',
            'data': [2071],
          },
          {
            'modis_date': 'A2026225',
            'data': [1896],
          },
        ],
      };
      expect(
        NDVIService.extrairNDVIMaisRecente(resposta),
        closeTo(0.2071, 1e-9),
      );
    });

    test('ignora valor de preenchimento e usa a anterior', () {
      final resposta = {
        'scale': '0.0001',
        'subset': [
          {
            'modis_date': 'A2026241',
            'data': [6500],
          },
          {
            'modis_date': 'A2026257',
            'data': [-3000],
          },
        ],
      };
      expect(NDVIService.extrairNDVIMaisRecente(resposta), closeTo(0.65, 1e-9));
    });

    test('limita NDVI negativo (água) a 0.0', () {
      final resposta = {
        'subset': [
          {
            'modis_date': 'A2026257',
            'data': [-1500],
          },
        ],
      };
      expect(NDVIService.extrairNDVIMaisRecente(resposta), 0.0);
    });

    test('retorna null sem valores válidos', () {
      expect(NDVIService.extrairNDVIMaisRecente({'subset': []}), isNull);
    });
  });
}
