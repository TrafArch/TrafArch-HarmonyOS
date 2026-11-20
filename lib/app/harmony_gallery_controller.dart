import 'dart:async';

import 'package:flutter/material.dart' show DateUtils, TimeOfDay;

import '../features/archive/data/app_database.dart';
import '../features/archive/domain/card_name_extension.dart';
import '../features/archive/domain/card_session_snapshot.dart';
import '../features/archive/domain/card_types.dart';
import '../features/transit_analysis/shanghai_balance_display.dart';
import '../features/transit_analysis/tunion_analysis_models.dart';
import '../gallery/gallery_controller.dart';
import '../gallery/gallery_data.dart';
import '../platform/nfc/nfc_models.dart';
import 'app_dependencies.dart';

class HarmonyGalleryController extends GalleryController {
  HarmonyGalleryController(this.app)
    : _current = GalleryCard.live(id: 'unread', name: '尚未读取卡片'),
      super(
        GalleryData({
          'cards': <GalleryRecord>[],
          'trips': <GalleryRecord>[],
          'footprints': <GalleryRecord>[],
          'scenes': <Object>[],
          'ledgers': <String, Object>{},
          'raw': <String, Object>{},
          'sources': ['全部来源', '交易明细 0x18'],
          'modes': ['全部方式', '轨道交通', '公交', '其他'],
        }),
      );

  final AppDependencies app;
  GalleryCard _current;
  NfcScanResult? _tag;
  List<SavedCard> _archive = const [];
  final Map<String, List<GalleryRecord>> _ledgers = {};
  StreamSubscription<List<SavedCard>>? _archiveStream;
  Future<void>? _ready;
  String? _fingerprint;
  String? _readNotice;
  String? _archiveNotice;
  int _attempt = 0;
  bool _closed = false;
  bool _saving = false;
  Future<void>? _closing;

  @override
  bool get isLive => true;

  @override
  GalleryCard get current => _current;

  @override
  String? get readNotice => _readNotice;

  @override
  String? get archiveNotice => _archiveNotice;

  @override
  bool get canSaveCurrent =>
      !_saving &&
      hasRead &&
      app.pendingCardSave?.fingerprint == _fingerprint &&
      _fingerprint != null;

  @override
  List<GalleryRecord> ledger(GalleryCard card) => _ledgers[card.id] ?? const [];

  @override
  Map<String, String> get readMetadata {
    final tag = _tag;
    if (tag == null) return const {};
    return {
      '连接类型': tag.technologies.join(' / '),
      'ATQA': ?tag.atqa,
      'SAK': ?tag.sak,
      '历史字节': ?tag.historicalBytes,
      'NFC-F 系统码': ?tag.nfcFSystemCode,
    };
  }

  void initialize() {
    _ready ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await app.init();
      if (_closed) return;
      autoSave = app.autoSaveEnabled;
      includeOverdraft = app.includeShanghaiOverdraft;
      _archiveStream = app.cardRepository.watchCards().listen(
        (items) {
          if (_closed) return;
          _setArchive(items);
          _archiveNotice = null;
          _updateArchive();
          notifyListeners();
        },
        onError: (Object _) {
          if (_closed) return;
          _archiveNotice = '无法打开本地档案库';
          notifyListeners();
        },
      );
    } catch (_) {
      if (_closed) return;
      _archiveNotice = '无法初始化本地数据';
      notifyListeners();
    }
  }

  void _setArchive(List<SavedCard> items) {
    _archive = items;
    _ledgers.clear();
    for (final item in items) {
      final json = item.sessionDataJson;
      final snapshot = json == null ? null : CardSessionSnapshot.decode(json);
      if (snapshot != null) {
        _ledgers[item.id] = _projectTrips(snapshot.trips, snapshot.context);
      }
    }
  }

  void _updateArchive() {
    final matched = _archive
        .where((item) => item.cardFingerprint == _fingerprint)
        .firstOrNull;
    _current.saved = matched != null && app.pendingCardSave == null;
    if (_current.saved && matched != null) _current.name = matched.displayName;
    cards = [
      for (final item in _archive)
        _card(
          id: item.id,
          name: item.displayName,
          number: item.cardNumber,
          city: item.cityName,
          cardType: item.cardType,
          amount: ShanghaiBalanceDisplay.forCard(
            includeShanghaiOverdraft: includeOverdraft,
            cardType: item.cardType,
            currencyCode: item.currencyCode,
          ).balanceFen(item.balanceFen),
          currency: item.currencyCode,
          readAt: item.lastReadAt == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(item.lastReadAt!),
          count: item.transactionCount,
          saved: true,
        ),
    ];
  }

  @override
  void read({bool fail = false}) {
    if (_closed || _saving || readState == GalleryReadState.reading) return;
    final attempt = ++_attempt;
    _readNotice = null;
    readState = GalleryReadState.reading;
    notifyListeners();
    unawaited(_read(attempt));
  }

  Future<void> _read(int attempt) async {
    bool active() => !_closed && attempt == _attempt;
    try {
      await _ready;
      await _closing;
      if (!active()) return;
      await app.scanOnce();
      if (!active()) return;
      final tag = app.lastResult;
      final capture = app.lastCapture;
      final verifiedBalance = app.currentOctopusResult;
      if (tag == null ||
          app.error != null && capture == null && verifiedBalance == null) {
        _failRead(app.error ?? '未读取到卡片');
        return;
      }
      _tag = tag;
      _fingerprint = capture?.fingerprint;
      final currency = verifiedBalance != null ? 'HKD' : capture?.currencyCode;
      final amount =
          verifiedBalance?.balanceMinor ??
          app.balanceDisplay.balanceFen(capture?.balanceFen);
      _current = _card(
        id: 'live-${tag.sessionId ?? attempt}',
        name:
            capture?.displayName ??
            app.lastIdentified?.displayName ??
            app.parsedCard?.parserName ??
            'NFC 卡片',
        number: capture?.cardNumber,
        city: capture?.identity.cityName,
        cardType: capture?.identity.cardType,
        amount: amount,
        currency: currency,
        readAt: capture?.readAt ?? tag.timestamp,
        count: capture?.transactionCount,
        tunion: app.tunionDetected,
        cityUnion: app.cityUnionDetected || app.dualApplicationDetected,
      );
      _readNotice = app.error ?? app.octopusReadNotice;
      final payload = capture?.sessionDataJson;
      final snapshot = payload == null
          ? null
          : CardSessionSnapshot.decode(payload);
      trips = snapshot != null
          ? _projectTrips(snapshot.trips, snapshot.context)
          : const [];
      _updateArchive();
      hasRead = true;
      readState = GalleryReadState.success;
      notifyListeners();
    } catch (_) {
      if (active()) _failRead('读卡失败，请重新贴卡');
    }
  }

  void _failRead(String notice) {
    _readNotice = notice;
    readState = GalleryReadState.failed;
    notifyListeners();
  }

  @override
  void cancelRead() {
    if (readState != GalleryReadState.reading) return;
    _attempt++;
    _closing = app.stop().catchError((Object _) {});
    super.cancelRead();
    notifyListeners();
  }

  @override
  Future<bool> saveCurrent(String name) async {
    final pending = app.pendingCardSave;
    if (!canSaveCurrent || pending == null) return false;
    _saving = true;
    notifyListeners();
    try {
      if (!await app.acceptPendingSave(pending.pendingSaveId)) return false;
      final items = await app.cardRepository.getAllCards();
      final match = items
          .where((item) => item.cardFingerprint == _fingerprint)
          .firstOrNull;
      if (match == null) return false;
      final custom = name.trim();
      if (custom.isNotEmpty &&
          custom != pending.displayName &&
          custom != match.customName) {
        await app.cardRepository.renameCard(match.id, custom);
      }
      if (_closed) return false;
      final updated = await app.cardRepository.getAllCards();
      if (_closed) return false;
      update(() {
        _setArchive(updated);
        _updateArchive();
        if (overlay == GalleryOverlay.save) overlay = null;
      });
      return true;
    } catch (_) {
      return false;
    } finally {
      _saving = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void setAutoSave(bool value) {
    unawaited(_setAutoSave(value));
  }

  Future<void> _setAutoSave(bool value) async {
    try {
      await app.setAutoSaveEnabled(value);
      if (_closed) return;
      update(() => autoSave = app.autoSaveEnabled);
    } catch (_) {
      if (_closed) return;
      _archiveNotice = '无法保存自动保存偏好';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    super.dispose();
    _closed = true;
    unawaited(_archiveStream?.cancel());
  }

  static List<GalleryRecord> _projectTrips(
    List<TransitTrip> transactions,
    ArchiveContext context,
  ) {
    final sorted = [...transactions]
      ..sort((left, right) => right.time.compareTo(left.time));
    return [
      for (final transaction in sorted) _projectTrip(transaction, context),
    ];
  }

  static GalleryRecord _projectTrip(TransitTrip trip, ArchiveContext context) {
    final mode = switch (trip.appTypeCode) {
      0x01 || 0x0A || 0x0E => '轨道交通',
      0x02 => '公交',
      _ => '其他',
    };
    final dateTime = trip.time.toIso8601String().split('T');
    final location = trip.stationLabel ?? trip.lineLabel;
    final title = location == null
        ? trip.typeName
        : '${trip.typeName} · $location';
    return {
      'kind': 'event',
      'mode': mode,
      'title': title,
      'sub': location ?? '位置未记录',
      'date': dateTime.first,
      'time': dateTime.last.substring(0, 5),
      'city': trip.cityName ?? '未记录',
      'source': '交易明细 0x18',
      'amount': context.formatAmount(
        trip.isConsume ? -trip.amountFen.abs() : trip.amountFen,
      ),
    };
  }

  @override
  List<GalleryRecord> get filteredTrips => !hasRead
      ? const []
      : [
          for (final trip in trips)
            if ((source == '全部来源' || source == trip['source']) &&
                (mode == '全部方式' || mode == trip['mode']))
              trip,
        ];

  static GalleryCard _card({
    required String id,
    required String name,
    String? number,
    String? city,
    String? cardType,
    int? amount,
    String? currency,
    DateTime? readAt,
    int? count,
    bool saved = false,
    bool tunion = false,
    bool cityUnion = false,
  }) {
    final local = readAt?.toLocal();
    final date = local == null
        ? ''
        : '${DateUtils.dateOnly(local).toIso8601String().split('T').first} '
              '${TimeOfDay.fromDateTime(local).hour.toString().padLeft(2, '0')}:'
              '${TimeOfDay.fromDateTime(local).minute.toString().padLeft(2, '0')}';
    final balance = switch ((amount, currency)) {
      (final int value, 'CNY') => GalleryCurrency.cny.format(value),
      (final int value, 'JPY') => GalleryCurrency.jpy.format(value),
      (final int value, 'HKD') => GalleryCurrency.hkd.format(value),
      (final int value, 'MOP') => 'MOP\$${formatGalleryMoney(value)}',
      _ => '暂不可用',
    };
    return GalleryCard.live(
      id: id,
      name: name,
      saved: saved,
      pan: number ?? '未读取',
      tail: number == null
          ? '—'
          : number.length < 4
          ? '—'
          : number.substring(number.length - 4),
      city: city ?? '未知',
      type: cardType == null ? '未知' : cardTypeLabel(cardType),
      rawBalance: balance,
      liveCurrencyCode: currency ?? '',
      when: date,
      count: count?.toString() ?? '—',
      applications: [
        if (tunion ||
            cardType == CardTypes.chinaTunion ||
            cardType == CardTypes.shanghaiTransitUnion)
          'tu',
        if (cityUnion || cardType == CardTypes.cityUnion) 'cu',
        if (cardType == CardTypes.suica) 'suica',
        if (cardType == CardTypes.octopusTunion || currency == 'HKD') 'octopus',
      ],
    );
  }
}
