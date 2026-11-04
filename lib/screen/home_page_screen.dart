import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';

import '../core/navigation/app_routes.dart';
import '../core/notifications/notification_service.dart';
import '../database/incendio_service.dart';
import '../database/wind_service.dart';
import '../database/ndvi_service.dart';
import '../database/fire_propagation_service.dart';
import '../model/incendio_model.dart';
import '../model/wind_data.dart';
import '../model/fire_propagation_data.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Tela principal do aplicativo
/// Exibe mapa interativo com incêndios, localização do usuário e zonas de propagação
class HomePageScreen extends StatefulWidget {
  const HomePageScreen({super.key});

  @override
  State<HomePageScreen> createState() => _HomePageScreenState();
}

class _HomePageScreenState extends State<HomePageScreen> {
  /// Controlador do mapa para gerenciar zoom, pan, etc.
  final MapController mapController = MapController();

  /// Gerenciador de localização do dispositivo
  final Location _location = Location();

  /// Serviços Firebase
  final IncendioService _incendioService = IncendioService();
  final WindService _windService = WindService();
  final NDVIService _ndviService = NDVIService();
  final FirePropagationService _propagationService = FirePropagationService();

  /// Calcular distância entre duas coordenadas
  final Distance _distance = const Distance();

  /// Controla quais incêndios já notificaram o usuário
  final Set<String> _notifiedIncendios = {};

  /// Localização atual do dispositivo
  LatLng? _currentLocation;

  /// Lista de incêndios carregados do banco de dados
  List<IncendioModel> _incendios = [];

  /// Polígonos de propagação de fogo a exibir no mapa
  List<Polygon> _propagationPolygons = [];

  /// Indica se localização está sendo carregada
  bool _isLoadingLocation = true;

  /// Controla se o mapa já foi centralizado na localização do usuário
  bool _hasCenteredOnUser = false;

  /// Ponto inicial do mapa (Campus IF Goiano – Ceres)
  /// Usado como fallback se localização não estiver disponível
  final LatLng initialPoint = LatLng(-15.3080, -49.6050);

  @override
  void initState() {
    super.initState();
    _initLocation();
    _listenIncendios();
  }

  Future<void> _initLocation() async {
    final serviceEnabled =
        await _location.serviceEnabled() || await _location.requestService();
    if (!serviceEnabled) {
      setState(() => _isLoadingLocation = false);
      return;
    }

    var permission = await _location.hasPermission();
    if (permission == PermissionStatus.denied) {
      permission = await _location.requestPermission();
    }
    if (permission != PermissionStatus.granted &&
        permission != PermissionStatus.grantedLimited) {
      setState(() => _isLoadingLocation = false);
      return;
    }

    // Última posição conhecida para centralizar rápido
    try {
      final lastLoc = await _location.getLocation();
      if (lastLoc.latitude != null && lastLoc.longitude != null) {
        _currentLocation = LatLng(lastLoc.latitude!, lastLoc.longitude!);
        _isLoadingLocation = false;
        mapController.move(_currentLocation!, 15);
        _hasCenteredOnUser = true;
      }
    } catch (_) {}

    _location.onLocationChanged.listen(
      (loc) {
        if (loc.latitude != null && loc.longitude != null) {
          setState(() {
            _currentLocation = LatLng(loc.latitude!, loc.longitude!);
            _isLoadingLocation = false;
            if (!_hasCenteredOnUser) {
              mapController.move(_currentLocation!, 15);
              _hasCenteredOnUser = true;
            }
          });
        }
      },
      onError: (e) {
        setState(() => _isLoadingLocation = false);
        debugPrint('❌ Erro de localização: $e');
      },
    );
  }

  void _listenIncendios() {
    debugPrint('🗺️ [Home] Iniciando stream de incêndios...');
    _incendioService.streamIncendios().listen(
      (incendios) {
        debugPrint('🔥 [Home] Recebido ${incendios.length} incêndios');
        if (_currentLocation != null) {
          _notifyNearbyIncendios(incendios);
        }
        setState(() {
          _incendios = incendios;
        });
      },
      onError: (e) {
        debugPrint('❌ [Home] Erro no stream de incêndios: $e');
      },
    );
  }

  void _notifyNearbyIncendios(List<IncendioModel> incendios) {
    if (_currentLocation == null) return;

    for (final inc in incendios) {
      if (inc.latitude == null || inc.longitude == null) continue;

      final distanciaKm = _distance.as(
        LengthUnit.Kilometer,
        _currentLocation!,
        LatLng(inc.latitude!, inc.longitude!),
      );

      final id = inc.id ?? '${inc.latitude}-${inc.longitude}-${inc.criadoEm}';

      if (distanciaKm <= 5 && !_notifiedIncendios.contains(id)) {
        _notifiedIncendios.add(id);
        NotificationService.showNearbyIncendio(
          id: id,
          titulo: 'Incêndio perto de você',
          corpo:
              '${inc.descricao} • ${distanciaKm.toStringAsFixed(1)} km de distância',
        );
      }
    }
  }

  /// Recentraliza o mapa na localização atual do usuário
  /// Zoom padrão: nível 15
  void _recenterMap() {
    if (_currentLocation != null) {
      mapController.move(_currentLocation!, 15);
      _hasCenteredOnUser = true;
    }
  }

  /// Constrói polígonos visuais das zonas de propagação de fogo
  ///
  /// Zonas primárias: vermelho com 18% opacidade, borda 3px
  /// Zonas secundárias: laranja com 12% opacidade, borda 2px
  ///
  /// @param data - Dados de propagação com zonas calculadas
  /// @return Lista de polígonos prontos para exibição no mapa
  List<Polygon> _buildPropagationPolygons(FirePropagationData data) {
    debugPrint(
      '🔵 _buildPropagationPolygons chamado com ${data.zones.length} zonas',
    );
    debugPrint('🔵 Centro: ${data.centerLat}, ${data.centerLng}');

    return data.zones.map((zone) {
      debugPrint(
        '🔵 Construindo zona: ${zone.name}, ângulos ${zone.startAngle}-${zone.endAngle}, dist ${zone.maxDistanceMeters}m',
      );

      final polyPoints = _buildZonePolygon(
        zone,
        data.centerLat,
        data.centerLng,
        steps: 30,
      );

      debugPrint('🔵 Zona ${zone.name} tem ${polyPoints.length} pontos');
      if (polyPoints.isNotEmpty) {
        debugPrint(
          '🔵 Primeiro ponto: ${polyPoints.first.latitude}, ${polyPoints.first.longitude}',
        );
      }

      // Define cores diferentes para cada tipo de zona
      Color color;
      double opacity;
      double borderOpacity;

      if (zone.isPrimary) {
        color = Colors.red;
        opacity = 0.25;
        borderOpacity = 0.7;
      } else if (zone.intensity > 0.5) {
        color = Colors.orange;
        opacity = 0.18;
        borderOpacity = 0.6;
      } else {
        color = Colors.yellow.shade700;
        opacity = 0.12;
        borderOpacity = 0.5;
      }

      return Polygon(
        points: polyPoints,
        color: color.withOpacity(opacity),
        borderColor: color.withOpacity(borderOpacity),
        borderStrokeWidth: zone.isPrimary ? 3 : 2,
        isFilled: true,
      );
    }).toList();
  }

  /// Gera pontos do polígono de uma zona de propagação
  List<LatLng> _buildZonePolygon(
    PropagationZone zone,
    double centerLat,
    double centerLng, {
    int steps = 30, // Aumentado para suavizar a curva
  }) {
    final points = <LatLng>[];

    // Adiciona o centro como primeiro ponto
    points.add(LatLng(centerLat, centerLng));

    // Normaliza ângulos para garantir que estejam entre 0-360
    double startAngle = zone.startAngle % 360;
    double endAngle = zone.endAngle % 360;

    // Se o ângulo cruza o norte (360°/0°), ajusta
    if (endAngle < startAngle) {
      endAngle += 360;
    }

    final spreadAngle = endAngle - startAngle;
    final angleStep = spreadAngle / steps;

    // Gera pontos ao longo do arco
    for (int i = 0; i <= steps; i++) {
      final angle = startAngle + (i * angleStep);
      final radians = angle * math.pi / 180;

      // Converte distância em metros para graus (aproximação)
      // 1 grau de latitude ≈ 111km
      // 1 grau de longitude varia com a latitude
      final distLatDeg = zone.maxDistanceMeters / 111000;
      final distLngDeg =
          zone.maxDistanceMeters /
          (111000 * math.cos(centerLat * math.pi / 180));

      // Calcula nova posição
      // Note: 0° = Norte, 90° = Leste, 180° = Sul, 270° = Oeste
      final lat = centerLat + (distLatDeg * math.cos(radians));
      final lng = centerLng + (distLngDeg * math.sin(radians));

      points.add(LatLng(lat, lng));
    }

    // Fecha o polígono voltando ao centro
    points.add(LatLng(centerLat, centerLng));

    return points;
  }

  /// Exibe diálogo com detalhes completos de um incêndio
  ///
  /// Ao abrir:
  /// 1. Limpa polígonos de propagação anteriores
  /// 2. Carrega dados meteorológicos (vento, temperatura, umidade)
  /// 3. Calcula NDVI da região
  /// 4. Calcula zonas de propagação (4 zonas)
  /// 5. Exibe polígonos no mapa
  /// 6. Mostra diálogo com foto, dados e botões de ação
  void _mostrarDetalhesIncendio(IncendioModel inc, LatLng pontoToque) async {
    debugPrint('📍 Dialog aberto para: ${inc.descricao}');

    // Limpa polígonos anteriores
    setState(() => _propagationPolygons = []);

    // Busca dados meteorológicos e calcula propagação
    WindData? windData;
    double? ndvi;
    FirePropagationData? propagationData;

    if (inc.latitude != null && inc.longitude != null) {
      // Busca dados de vento
      windData = await _windService.getWindData(inc.latitude!, inc.longitude!);
      debugPrint(
        '🌬️ Dados de vento: ${windData?.windSpeed} m/s, ${windData?.windDirection}°',
      );

      // Calcula NDVI
      ndvi = await _ndviService.getNDVIIndex(inc.latitude!, inc.longitude!);
      debugPrint('🌱 NDVI calculado: $ndvi');

      // Calcula zonas de propagação se tiver dados de vento
      if (windData != null) {
        propagationData = await _propagationService.calculate(
          inc.latitude!,
          inc.longitude!,
        );

        // Cria polígonos de propagação
        if (propagationData != null) {
          debugPrint(
            '🎯 Centro do incêndio: ${inc.latitude}, ${inc.longitude}',
          );
          debugPrint(
            '🎯 Centro da propagação: ${propagationData.centerLat}, ${propagationData.centerLng}',
          );

          final newPolygons = _buildPropagationPolygons(propagationData);
          debugPrint('🔴 Polígonos construídos: ${newPolygons.length}');

          setState(() {
            _propagationPolygons = newPolygons;
            debugPrint(
              '🔴 _propagationPolygons atualizado: ${_propagationPolygons.length} polígonos',
            );
          });

          // Garante que o mapa esteja centralizado no incêndio selecionado
          // para que as zonas apareçam ao redor do foco
          try {
            mapController.move(
              LatLng(propagationData.centerLat, propagationData.centerLng),
              mapController.camera.zoom,
            );
          } catch (e) {
            debugPrint('⚠️ Erro ao recentralizar mapa: $e');
          }

          debugPrint(
            '🔥 Zonas de propagação calculadas: ${propagationData.zones.length} zonas',
          );
          debugPrint(
            '📍 Polígonos no estado: ${_propagationPolygons.length} polígonos',
          );
        }
      }
    }

    debugPrint('🔍 [Dialog Debug] Descrição completa: "${inc.descricao}"');
    debugPrint(
      '🔍 [Dialog Debug] Foto URL (primeiros 100 chars): "${inc.fotoUrl?.substring(0, math.min(100, inc.fotoUrl?.length ?? 0)) ?? "null"}"',
    );
    debugPrint(
      '🔍 [Dialog Debug] Tamanho Foto URL: ${inc.fotoUrl?.length ?? 0} bytes',
    );
    debugPrint('🔍 [Dialog Debug] Direção: ${inc.direcao}°');
    debugPrint('🔍 [Dialog Debug] Distância: ${inc.distanciaMetros}m');

    DateTime dataHora = DateTime.parse(inc.criadoEm);
    String dataFormatada =
        '${dataHora.day} de ${_getNomeMes(dataHora.month)}, ${dataHora.hour.toString().padLeft(2, '0')}:${dataHora.minute.toString().padLeft(2, '0')}';

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Container(
            padding: const EdgeInsets.all(0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (inc.fotoUrl != null && inc.fotoUrl!.isNotEmpty)
                    ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                      ),
                      child: Builder(
                        builder: (context) {
                          try {
                            final decodedBytes = base64Decode(inc.fotoUrl!);
                            debugPrint(
                              '✅ Foto decodificada com sucesso: ${decodedBytes.length} bytes',
                            );
                            return Image.memory(
                              decodedBytes,
                              height: 250,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                debugPrint(
                                  '❌ Erro ao exibir Image.memory: $error',
                                );
                                return Container(
                                  height: 250,
                                  color: Colors.grey.shade300,
                                  child: const Center(
                                    child: Icon(
                                      Icons.broken_image,
                                      size: 60,
                                      color: Colors.grey,
                                    ),
                                  ),
                                );
                              },
                            );
                          } catch (e) {
                            debugPrint('❌ Erro ao decodificar Base64: $e');
                            return Container(
                              height: 250,
                              color: Colors.grey.shade300,
                              child: const Center(
                                child: Icon(
                                  Icons.broken_image,
                                  size: 60,
                                  color: Colors.grey,
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    )
                  else
                    Container(
                      height: 250,
                      decoration: BoxDecoration(
                        color: _getCorPorRisco(inc.nivelRisco).withOpacity(0.2),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.local_fire_department,
                          size: 80,
                          color: _getCorPorRisco(inc.nivelRisco),
                        ),
                      ),
                    ),

                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    inc.descricao,
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      height: 1.3,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _getCorPorRisco(
                                        inc.nivelRisco,
                                      ).withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'Risco: ${inc.nivelRisco}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                        color: _getCorPorRisco(inc.nivelRisco),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.calendar_today,
                                size: 18,
                                color: Colors.grey.shade700,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                dataFormatada,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey.shade800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        if (inc.direcao != null || inc.distanciaMetros != null)
                          Row(
                            children: [
                              if (inc.direcao != null)
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.shade50,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: Colors.blue.shade200,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.explore,
                                              size: 16,
                                              color: Colors.blue.shade700,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Direção',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.blue.shade700,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${inc.direcao!.toStringAsFixed(0)}°',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.blue,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (inc.direcao != null &&
                                  inc.distanciaMetros != null)
                                const SizedBox(width: 10),
                              if (inc.distanciaMetros != null)
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.orange.shade50,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: Colors.orange.shade200,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.straighten,
                                              size: 16,
                                              color: Colors.orange.shade700,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Distância',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.orange.shade700,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${inc.distanciaMetros!.toStringAsFixed(0)} m',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.orange,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        const SizedBox(height: 16),

                        // Card de Vento
                        if (windData != null)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.blue.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.air,
                                      size: 20,
                                      color: Colors.blue.shade700,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Vento (dados em tempo real)',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blue.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '${windData.windSpeed.toStringAsFixed(1)} m/s, Direção: ${windData.windDirection.toStringAsFixed(0)}° (${_getCardinalDirection(windData.windDirection)})',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade900,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Temp: ${windData.temperature.toStringAsFixed(1)}°C  •  Umidade: ${windData.humidity.toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),

                        if (windData != null) const SizedBox(height: 12),

                        // Card de Propagação
                        if (propagationData != null)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.orange.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.local_fire_department,
                                      size: 20,
                                      color: Colors.orange.shade700,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Propagação estimada (1h)',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.orange.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Vento ${propagationData.windSpeed.toStringAsFixed(1)} m/s @ ${propagationData.windDirection.toStringAsFixed(0)}° • NDVI ${propagationData.ndvi.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ...propagationData.zones.map(
                                  (zone) => Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: zone.isPrimary
                                            ? Colors.red.shade100
                                            : Colors.orange.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: zone.isPrimary
                                              ? Colors.red.shade300
                                              : Colors.orange.shade300,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  zone.name,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.bold,
                                                    color: zone.isPrimary
                                                        ? Colors.red.shade900
                                                        : Colors
                                                              .orange
                                                              .shade900,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  'Ângulos ${zone.startAngle.toStringAsFixed(0)}° - ${zone.endAngle.toStringAsFixed(0)}°',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.grey.shade700,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            '${(zone.maxDistanceMeters / 1000).toStringAsFixed(2)} km',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: zone.isPrimary
                                                  ? Colors.red.shade700
                                                  : Colors.orange.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                Text(
                                  'Polígonos desenhados no mapa para visualização.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),

                        if (propagationData != null) const SizedBox(height: 12),

                        // Card de Vegetação (NDVI)
                        if (ndvi != null)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.green.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.eco,
                                      size: 20,
                                      color: Colors.green.shade700,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Vegetação (NDVI)',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _getNDVIDescription(ndvi),
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.green.shade900,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: ndvi,
                                    minHeight: 8,
                                    backgroundColor: Colors.grey.shade300,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      _getNDVIColor(ndvi),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'NDVI: ${ndvi.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),

                        if (ndvi != null) const SizedBox(height: 20),

                        Text(
                          '📍 COORDENADAS',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade700,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Centro do Incêndio:',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Lat: ${inc.latitude?.toStringAsFixed(6) ?? "N/A"}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              Text(
                                'Lng: ${inc.longitude?.toStringAsFixed(6) ?? "N/A"}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),

                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () {
                              Navigator.pop(context);
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _getCorPorRisco(inc.nivelRisco),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text(
                              'Fechar',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _getNomeMes(int mes) {
    const meses = [
      'jan',
      'fev',
      'mar',
      'abr',
      'mai',
      'jun',
      'jul',
      'ago',
      'set',
      'out',
      'nov',
      'dez',
    ];
    return meses[mes - 1];
  }

  /// Converte graus em direção cardeal (N, NE, E, SE, S, SW, W, NW)
  String _getCardinalDirection(double degrees) {
    const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final index = ((degrees + 22.5) / 45).floor() % 8;
    return directions[index];
  }

  /// Retorna descrição textual baseada no valor do NDVI
  String _getNDVIDescription(double ndvi) {
    if (ndvi < 0.2) return 'Solo exposto ou área urbana';
    if (ndvi < 0.4) return 'Vegetação esparsa';
    if (ndvi < 0.6) return 'Vegetação moderada';
    if (ndvi < 0.8) return 'Vegetação densa (floresta/cerrado)';
    return 'Vegetação muito densa';
  }

  /// Retorna cor visual baseada no valor do NDVI
  Color _getNDVIColor(double ndvi) {
    if (ndvi < 0.2) return Colors.brown;
    if (ndvi < 0.4) return Colors.yellow.shade700;
    if (ndvi < 0.6) return Colors.lightGreen;
    if (ndvi < 0.8) return Colors.green;
    return Colors.green.shade900;
  }

  void _handleMapaTap(LatLng tap) {
    for (final inc in _incendios) {
      if (inc.areaPoligono.isEmpty) continue;
      if (_pointInPolygon(tap, inc.areaPoligono)) {
        debugPrint('🔥 Tap dentro do polígono: ${inc.descricao}');
        _mostrarDetalhesIncendio(inc, tap);
        return;
      }
    }
  }

  bool _pointInPolygon(LatLng tap, List<LatLng> poly) {
    bool inside = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final xi = poly[i].latitude;
      final yi = poly[i].longitude;
      final xj = poly[j].latitude;
      final yj = poly[j].longitude;

      final intersect =
          ((yi > tap.longitude) != (yj > tap.longitude)) &&
          (tap.latitude <
              (xj - xi) * (tap.longitude - yi) / (yj - yi + 1e-12) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  Color _getCorPorRisco(String nivelRisco) {
    switch (nivelRisco.toLowerCase()) {
      case 'alto':
        return Colors.red;
      case 'medio':
      case 'médio':
        return Colors.orange;
      default:
        return Colors.yellow.shade700;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: _currentLocation ?? initialPoint,
              initialZoom: 15,
              maxZoom: 19,
              minZoom: 3,
              onTap: (tapPosition, latLng) => _handleMapaTap(latLng),
            ),
            children: [
              TileLayer(
                urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                userAgentPackageName: "com.fireapp.app",
              ),
              CurrentLocationLayer(
                style: const LocationMarkerStyle(
                  marker: DefaultLocationMarker(),
                  markerSize: Size(35, 35),
                  markerDirection: MarkerDirection.heading,
                ),
              ),
              // Layer de polígonos de área de incêndio
              PolygonLayer(
                polygons: _incendios
                    .where((inc) => inc.areaPoligono.isNotEmpty)
                    .map((inc) {
                      final cor = _getCorPorRisco(inc.nivelRisco);
                      return Polygon(
                        points: inc.areaPoligono,
                        color: cor.withOpacity(0.3),
                        borderColor: cor,
                        borderStrokeWidth: 2,
                        isFilled: true,
                      );
                    })
                    .toList(),
              ),
              // Layer de polígonos de propagação do fogo
              PolygonLayer(polygons: _propagationPolygons),
              MarkerLayer(
                markers: _incendios
                    .where(
                      (inc) => inc.latitude != null && inc.longitude != null,
                    )
                    .map((inc) {
                      final cor = _getCorPorRisco(inc.nivelRisco);
                      final centerPoint = LatLng(
                        inc.latitude ?? 0,
                        inc.longitude ?? 0,
                      );
                      return Marker(
                        point: centerPoint,
                        width: 40,
                        height: 40,
                        child: GestureDetector(
                          onTap: () {
                            debugPrint(
                              '🔥 Marcador tocado! Abrindo detalhes do incêndio: ${inc.descricao}',
                            );
                            _mostrarDetalhesIncendio(inc, centerPoint);
                          },
                          child: Icon(
                            Icons.local_fire_department,
                            color: cor,
                            size: 36,
                            shadows: [
                              Shadow(
                                offset: const Offset(0, 2),
                                blurRadius: 4,
                                color: Colors.black.withOpacity(0.5),
                              ),
                            ],
                          ),
                        ),
                      );
                    })
                    .toList(),
              ),
            ],
          ),

          if (_isLoadingLocation)
            const Positioned(
              top: 12,
              right: 12,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),

          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            right: 12,
            child: SafeArea(
              child: GestureDetector(
                onTap: _recenterMap,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(8),
                  child: Image.asset('assets/logo.png', fit: BoxFit.contain),
                ),
              ),
            ),
          ),

          Positioned(
            top: 32,
            left: 20,
            child: GestureDetector(
              onTap: () {
                Navigator.pushNamed(context, AppRoutes.telaInicialAcao);
              },
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 5,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(Icons.menu, color: Colors.white, size: 32),
              ),
            ),
          ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(28),
                  topRight: Radius.circular(28),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _BottomButton(
                    icon: Icons.info_outline,
                    label: "Informações",
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.informacoes),
                  ),
                  _BottomButton(
                    icon: Icons.notifications_none_outlined,
                    label: "Notificações",
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.meusAlertas),
                  ),
                  _BottomButton(
                    icon: Icons.add_circle_outline,
                    label: "Adicionar",
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.cadastroIncendio,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _BottomButton({
    Key? key,
    required this.icon,
    required this.label,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 32),
          const SizedBox(height: 4),
          Text(label, style: AppTextStyles.small.copyWith(color: Colors.white)),
        ],
      ),
    );
  }
}
