import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Serviço para obter o índice NDVI (Normalized Difference Vegetation Index)
///
/// Usa o produto MODIS MOD13Q1 (composição de 16 dias, resolução de 250 m)
/// disponibilizado gratuitamente e sem autenticação pelo web service do
/// ORNL DAAC (NASA): https://modis.ornl.gov/data/modis_webservice.html
///
/// Se o serviço estiver indisponível, usa uma estimativa baseada na
/// distância de áreas urbanas conhecidas, para não bloquear o app.
class NDVIService {
  /// URL do endpoint de recorte (subset) do MOD13Q1
  static const String _baseUrl =
      'https://modis.ornl.gov/rst/api/v1/MOD13Q1/subset';

  /// Banda de NDVI do MOD13Q1
  static const String _band = '250m_16_days_NDVI';

  /// O serviço do ORNL pode demorar a responder
  static const Duration _timeout = Duration(seconds: 15);

  /// Janela de busca: cobre o atraso de publicação do MODIS (~3 semanas)
  /// e algumas composições de 16 dias, respeitando o limite de 10 datas
  /// por requisição do serviço
  static const int _janelaDias = 80;

  /// Valores brutos válidos do MOD13Q1 (fora disso é preenchimento, ex.: -3000)
  static const int _minValido = -2000;
  static const int _maxValido = 10000;

  /// Fator de escala padrão do MOD13Q1 (valor bruto × 0.0001 = NDVI)
  static const double _escalaPadrao = 0.0001;

  /// Cache em memória por coordenada (~100 m), já que o NDVI muda a cada
  /// 16 dias e a tela inicial consulta vários incêndios próximos
  static final Map<String, double> _cache = {};

  /// Raio da Terra em quilômetros (usado na fórmula de Haversine)
  static const double _earthRadiusKm = 6371.0;

  /// Coordenadas de referência de centros urbanos (baixa vegetação)
  /// Formato: [latitude, longitude]
  static const List<List<double>> _urbanCenters = [
    [-23.5505, -46.6333], // São Paulo
    [-22.9068, -43.1729], // Rio de Janeiro
    [-19.9167, -43.9345], // Belo Horizonte
    [-25.4284, -49.2733], // Curitiba
  ];

  /// Obtém o índice NDVI para uma localização
  ///
  /// Retorna o valor mais recente do satélite MODIS limitado a 0.0 a 1.0
  /// (valores negativos, como água, viram 0.0):
  /// - 0.0 a 0.2: Solo exposto ou área urbana
  /// - 0.2 a 0.4: Vegetação esparsa
  /// - 0.4 a 0.6: Vegetação moderada
  /// - 0.6 a 0.8: Vegetação densa
  /// - 0.8 a 1.0: Vegetação muito densa (florestas)
  Future<double> getNDVIIndex(double latitude, double longitude) async {
    final chave =
        '${latitude.toStringAsFixed(3)},${longitude.toStringAsFixed(3)}';
    final emCache = _cache[chave];
    if (emCache != null) return emCache;

    final ndvi = await _buscarNDVIModis(latitude, longitude);
    if (ndvi != null) {
      _cache[chave] = ndvi;
      return ndvi;
    }

    return _estimarNDVI(latitude, longitude);
  }

  /// Consulta o NDVI MODIS mais recente no web service do ORNL
  ///
  /// Retorna null se houver erro, timeout ou nenhum valor válido na janela
  Future<double?> _buscarNDVIModis(double latitude, double longitude) async {
    try {
      final hoje = DateTime.now().toUtc();
      final inicio = hoje.subtract(const Duration(days: _janelaDias));

      // kmAboveBelow/kmLeftRight = 0 retorna apenas o pixel do ponto
      final url = Uri.parse(_baseUrl).replace(
        queryParameters: {
          'latitude': '$latitude',
          'longitude': '$longitude',
          'band': _band,
          'startDate': formatarDataModis(inicio),
          'endDate': formatarDataModis(hoje),
          'kmAboveBelow': '0',
          'kmLeftRight': '0',
        },
      );

      debugPrint('🛰️ Requisitando NDVI MODIS: $url');

      final response = await http
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(_timeout);

      if (response.statusCode != 200) {
        debugPrint(
          '❌ Erro HTTP ${response.statusCode} no NDVI: ${response.body}',
        );
        return null;
      }

      final ndvi = extrairNDVIMaisRecente(json.decode(response.body));
      if (ndvi == null) {
        debugPrint('⚠️ Nenhum NDVI MODIS válido nos últimos $_janelaDias dias');
        return null;
      }

      debugPrint('🌿 NDVI MODIS: ${ndvi.toStringAsFixed(3)}');
      return ndvi;
    } catch (e) {
      debugPrint('❌ Erro ao obter NDVI MODIS: $e');
      return null;
    }
  }

  /// Extrai o NDVI válido mais recente de uma resposta do endpoint subset
  ///
  /// Ignora valores de preenchimento (ex.: -3000, sem dado por nuvem) e
  /// limita o resultado a 0.0 a 1.0
  static double? extrairNDVIMaisRecente(Map<String, dynamic> resposta) {
    final escala = double.tryParse('${resposta['scale']}') ?? _escalaPadrao;
    final subset = (resposta['subset'] as List?) ?? const [];

    // Ordena pela data MODIS (AYYYYDDD ordena corretamente como texto)
    final composicoes = subset.cast<Map<String, dynamic>>().toList()
      ..sort((a, b) => '${b['modis_date']}'.compareTo('${a['modis_date']}'));

    for (final composicao in composicoes) {
      final valores = (composicao['data'] as List?) ?? const [];
      if (valores.isEmpty) continue;

      final bruto = (valores.first as num).toInt();
      if (bruto < _minValido || bruto > _maxValido) continue;

      return (bruto * escala).clamp(0.0, 1.0).toDouble();
    }

    return null;
  }

  /// Formata uma data no padrão MODIS AYYYYDDD (ano + dia do ano)
  static String formatarDataModis(DateTime data) {
    final diaDoAno = data.difference(DateTime.utc(data.year, 1, 1)).inDays + 1;
    return 'A${data.year}${diaDoAno.toString().padLeft(3, '0')}';
  }

  /// Estimativa usada quando o MODIS está indisponível
  ///
  /// Quanto mais longe do centro urbano mais próximo (fórmula de
  /// Haversine), maior a densidade de vegetação estimada.
  double _estimarNDVI(double latitude, double longitude) {
    // Calcula distância até o centro urbano mais próximo
    double minDistance = double.infinity;

    for (var center in _urbanCenters) {
      final distance = _haversineDistance(
        latitude,
        longitude,
        center[0],
        center[1],
      );
      if (distance < minDistance) {
        minDistance = distance;
      }
    }

    // Converte distância em índice NDVI
    // Centros urbanos (0km) = NDVI 0.1
    // 50km de distância = NDVI 0.5
    // 100km+ de distância = NDVI 0.8
    double ndvi = 0.1 + (minDistance / 100.0) * 0.7;

    // Limita entre 0.1 e 0.9
    ndvi = ndvi.clamp(0.1, 0.9);

    debugPrint(
      '🌿 NDVI estimado (MODIS indisponível): ${ndvi.toStringAsFixed(3)} '
      '(distância do centro urbano: ${minDistance.toStringAsFixed(1)} km)',
    );

    return ndvi;
  }

  /// Calcula a distância entre dois pontos usando a fórmula de Haversine
  ///
  /// Parâmetros:
  /// - lat1, lon1: Coordenadas do primeiro ponto
  /// - lat2, lon2: Coordenadas do segundo ponto
  ///
  /// Retorna a distância em quilômetros
  double _haversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    // Converte graus para radianos
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final lat1Rad = _toRadians(lat1);
    final lat2Rad = _toRadians(lat2);

    // Fórmula de Haversine
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        sin(dLon / 2) * sin(dLon / 2) * cos(lat1Rad) * cos(lat2Rad);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return _earthRadiusKm * c;
  }

  /// Converte graus para radianos
  double _toRadians(double degrees) {
    return degrees * pi / 180.0;
  }
}
