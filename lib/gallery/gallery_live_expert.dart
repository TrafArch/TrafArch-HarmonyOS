part of 'gallery_app.dart';

enum _LiveExpertTab {
  information('信息获取', 'expert-info-get'),
  transit('交通数据解析', 'expert-parsed'),
  compliance('JT/T 978 符合性', 'expert-compliance'),
  raw('APDU / Raw Data', 'expert-apdu');

  const _LiveExpertTab(this.label, this.storageKey);
  final String label;
  final String storageKey;
}

extension _GalleryLiveExpert on _GalleryViewState {
  Widget _liveExpert(AppDependencies app) {
    if (!c.hasRead || c.readState == GalleryReadState.failed) {
      return _list([
        _empty(
          c.readState == GalleryReadState.reading ? '正在读取卡片' : '暂无本次读取结果',
          '读取卡片后展示解析字段与原始数据',
          icon: Icons.science_outlined,
          action: _button(
            '前往首页',
            () => c.navigate(GalleryPage.home),
            primary: true,
          ),
        ),
      ], id: 'expert');
    }
    final tabs = <_LiveExpertTab>[
      _LiveExpertTab.information,
      _LiveExpertTab.transit,
      if (CardParserIds.isTUnionFamily(app.parsedCard?.parserId))
        _LiveExpertTab.compliance,
      _LiveExpertTab.raw,
    ];
    final tab = c.expertTab >= tabs.length
        ? tabs.last
        : tabs[c.expertTab < 0 ? 0 : c.expertTab];
    return _list(
      [
        _tabs(
          [for (final item in tabs) item.label],
          tabs.indexOf(tab),
          (index) => c.update(() => c.expertTab = index),
          scroll: true,
          id: 'expert-live-tabs',
        ),
        _gap(16),
        _fade(
          tab.name,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: switch (tab) {
              _LiveExpertTab.information || _LiveExpertTab.transit => [
                for (final section in _liveExpertSections(app, tab))
                  _expand(
                    'live-expert:${tab.name}:${section['title']}',
                    section['title'] as String,
                    _liveExpertSectionChildren(section),
                    initiallyOpen: section['open'] == true,
                    collapsible: section['fixedOpen'] != true,
                  ),
                _gap(),
                _text(
                  '以上为本次读取保存在内存中的字段，未捕获内容保持未知。',
                  role: GalleryTypography.caption,
                  color: t.muted,
                ),
              ],
              _LiveExpertTab.compliance => [
                _panel(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final row in _liveComplianceRows(app))
                        _kv(row.$1, row.$2),
                    ],
                  ),
                ),
                _gap(),
                _text(
                  '此处仅汇总本次已读取文件；未读取项不推断为通过。',
                  role: GalleryTypography.caption,
                  color: t.muted,
                ),
              ],
              _LiveExpertTab.raw => _liveRawSections(app),
            },
          ),
        ),
      ],
      id: 'expert',
      positionId: tab.storageKey,
    );
  }

  List<Widget> _liveExpertSectionChildren(GalleryRecord section) {
    final children = <Widget>[];
    if (section['groups'] case final List groups) {
      for (var index = 0; index < groups.length; index++) {
        final group = groups[index] as Map;
        children.add(
          _liveExpertGroupHeader(group['title'] as String, first: index == 0),
        );
        for (final row in (group['rows'] as List).cast<List>()) {
          children.add(_kv(row[0] as String, row[1] as String));
        }
      }
    }
    if (section['rows'] case final List rows) {
      for (final row in rows.cast<List>()) {
        children.add(_kv(row[0] as String, row[1] as String));
      }
    }
    return children;
  }

  Widget _liveExpertGroupHeader(String title, {required bool first}) => Padding(
    padding: EdgeInsets.only(top: first ? 0 : 18, bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _text(title, role: GalleryTypography.label, weight: FontWeight.w600),
        _gap(6),
        Divider(height: 1, color: t.line),
      ],
    ),
  );

  List<GalleryRecord> _liveExpertSections(
    AppDependencies app,
    _LiveExpertTab tab,
  ) {
    final parsed = app.parsedCard;
    final felica = app.felicaResult;
    final local = app.localReadResult;
    final identified = app.lastIdentified;
    if (tab == _LiveExpertTab.information) {
      return [
        {
          'title': '卡片识别',
          'open': true,
          'rows': <List<String>>[
            ['卡片名称', c.current.name],
            ['解析器', parsed?.parserName ?? felica?.displayName ?? '未知'],
            ['选中 AID', parsed?.selectedAidHex ?? '未提供'],
            ['识别状态', identified?.identity.identificationSource ?? '未提供'],
            ['卡号', identified?.cardNumber ?? c.current.pan],
            ['识别城市', identified?.identity.cityName ?? c.current.city],
            ['卡种', identified?.identity.cardType ?? c.current.type],
            ['货币', app.cardCurrency.code],
            ['读取时间', c.current.when],
          ],
        },
        if (felica != null)
          {
            'title': 'FeliCa',
            'open': true,
            'rows': <List<String>>[
              ['产品', felica.displayName],
              ['IDm', felica.idm ?? '未知'],
              ['系统码', felica.systemCodeText],
              ['识别状态', felica.stateText],
              if (felica.transitCapability case final capability?)
                ['交通功能', capability],
            ],
          },
        if (local != null)
          {
            'title': '本地卡应用',
            'open': true,
            'rows': <List<String>>[
              ['卡型', local.info.cardKindLabel],
              [
                '卡号',
                local.info.cardNumber.isEmpty ? '未知' : local.info.cardNumber,
              ],
              [
                '钱包余额',
                local.info.observedBalance == null
                    ? '未知'
                    : '${local.info.observedBalance}',
              ],
              ['交易记录', '${local.trips.length} 条'],
            ],
          },
      ];
    }
    return _liveTransitSections(app);
  }

  List<GalleryRecord> _liveTransitSections(AppDependencies app) {
    final parsed = app.parsedCard;
    final info = parsed?.info;
    final analysis = app.analysis;
    final wallet = analysis?.wallet;
    final trips = analysis?.trips ?? const <TransitTrip>[];
    final process = app.transitProcessRecords;
    final values = ExpertValues(
      currency: app.cardCurrency,
      balanceDisplay: app.balanceDisplay,
      cityNameOf: app.cityNameOf,
    );
    final balance = parsed == null
        ? null
        : BalanceInterpretation.fromParsedCard(parsed);
    final sections = <GalleryRecord>[
      {
        'title': '交通应用信息',
        'open': true,
        'fixedOpen': true,
        'rows': <List<String>>[
          [
            '余额',
            c.current.unknownBalance
                ? '未知'
                : c.current.balance(c.includeOverdraft),
          ],
          ['币种', app.cardCurrency.code],
          ['余额语义', app.balanceDisplay.isCityUnionBalance ? '城市一卡通钱包' : '读取结果'],
          ['卡种', info?.cardKind ?? '未知'],
          ['发卡机构', info?.issuerId ?? '未知'],
          ['剩余有效天数', daysRemainingText(wallet?.daysRemaining)],
          if (balance != null &&
              parsed != null &&
              balance.semantics != BalanceSemantics.direct &&
              !app.balanceDisplay.isCityUnionBalance &&
              balance.observedBalanceText != null)
            [balance.observationLabel, balance.observedBalanceText!],
          if (CardParserIds.isTUnionFamily(parsed?.parserId)) ...[
            ['逻辑卡号', expertValue(info?.displayCardNumber)],
            ['应用类型标识', expertValue(info?.appTypeId)],
            ['应用版本', expertValue(info?.appVersion)],
            ['生效日期', expertDate(info?.effectiveDate)],
            ['失效日期', expertDate(info?.expireDate)],
            ['发卡机构 FCI', expertValue(info?.issuerFci)],
            ['国际代码', expertValue(info?.countryCode)],
            ['省级代码', expertValue(info?.provinceCode)],
            ['城市代码', expertValue(info?.cityCode)],
            ['互通卡种', expertValue(info?.interopCardType)],
            ['卡种类型', expertValue(info?.cardKind)],
          ],
        ],
      },
    ];
    if (CardParserIds.isTUnionFamily(parsed?.parserId)) {
      sections.addAll(_liveProcessSections(app, process, values));
      if (trips.isNotEmpty) {
        sections.add(_liveTransactionsSection(trips));
      }
    }
    if (app.cityUnionFiles.isNotEmpty) {
      sections.addAll(_liveCityUnionSections(app, parsed?.cityUnionBalanceFen));
    }
    return sections;
  }

  GalleryRecord _liveTransactionsSection(List<TransitTrip> trips) => {
    'title': '交易明细',
    'open': false,
    'groups': <GalleryRecord>[
      for (var index = 0; index < trips.length; index++)
        {
          'title': '交易 ${index + 1} · ${expertTime(trips[index].time)}',
          'rows': _liveTransactionRows(trips[index]),
        },
    ],
  };

  List<List<String>> _liveTransactionRows(TransitTrip trip) => [
    ['时间', expertTime(trip.time)],
    ['交易金额', trip.amountText],
    ['交易类型', trip.typeName],
    ['交易序号', '${trip.sequence}'],
    ['终端编号', trip.terminalId],
    ['终端解码', terminalDecodeText(trip)],
    if (trip.rawHex case final raw? when raw.isNotEmpty) ['原始数据', raw],
  ];

  List<GalleryRecord> _liveProcessSections(
    AppDependencies app,
    List<TUnionProcessRecord> process,
    ExpertValues values,
  ) {
    if (process.isEmpty) {
      return [
        {
          'title': '过程记录 · 0x1A / 0x1E',
          'open': false,
          'rows': <List<String>>[
            ['说明', '未读取到过程记录（卡片未实现该文件、记录为空或读取条件不满足）'],
          ],
        },
      ];
    }
    final varRecords = process.where((record) => record.sfi == 0x1A).toList();
    TUnionProcessRecord? railRecord;
    TUnionProcessRecord? busRecord;
    TUnionProcessRecord? wholeVarBlob;
    for (final record in varRecords) {
      switch (record.recordNumber) {
        case 1:
          railRecord = record;
          break;
        case 2:
          busRecord = record;
          break;
        case 0:
          wholeVarBlob = record;
          break;
      }
    }
    final railView = railRecord ?? wholeVarBlob;
    final railFallback = railRecord == null ? app.railTransitRecord : null;
    final cycleRecords = process.where((record) => record.sfi == 0x1E).toList();
    final sections = <GalleryRecord>[
      {
        'title': '0x1A · 城市轨道应用信息记录',
        'open': false,
        'rows': _liveRailRows(
          railView,
          railView?.railTransit ?? railFallback,
          values,
        ),
      },
      {
        'title': '0x1A · 公共汽电车应用信息记录',
        'open': false,
        'rows': _liveBusRows(busRecord, busRecord?.busTransit, values),
      },
    ];
    if (cycleRecords.isNotEmpty) {
      sections.add({
        'title': '0x1E · 循环记录（${cycleRecords.length} 条）',
        'open': false,
        'groups': <GalleryRecord>[
          for (final record in cycleRecords)
            {
              'title':
                  '${record.recordNumber > 0 ? '循环记录 ${record.recordNumber}' : record.recordName}'
                  ' · ${values.processRecordSubtitle(record)}',
              'rows': record.trip == null
                  ? <List<String>>[
                      ['字节数', '${record.raw.length} 字节'],
                      ['说明', '记录未写入或长度不足，未能解码为字段'],
                      ['原始数据', record.rawHex],
                    ]
                  : _liveCycleRows(record.trip!, values),
            },
        ],
      });
    }
    return sections;
  }

  List<List<String>> _liveRailRows(
    TUnionProcessRecord? record,
    TransitRecord? transit,
    ExpertValues values,
  ) {
    if (transit != null) {
      return [
        ['交易状态', codeName(transit.statusCode, transit.statusName)],
        ['进闸城市代码', values.cityCell(transit.entryCityCode)],
        ['出闸城市代码', values.cityCell(transit.exitCityCode)],
        ['进闸机构标识', hexLower(transit.entryAgencyId)],
        ['出闸机构标识', hexLower(transit.exitAgencyId)],
        ['进闸站点', hexLower(transit.entryStationId)],
        ['出闸站点', hexLower(transit.exitStationId)],
        ['进闸终端编号', hexLower(transit.entryTerminalId)],
        ['出闸终端编号', hexLower(transit.exitTerminalId)],
        ['进站时间', bcdTimeCell(transit.entryTime, transit.entryTimeBcd)],
        ['出站时间', bcdTimeCell(transit.exitTime, transit.exitTimeBcd)],
        ['标注金额', values.amountCell(transit.annotateAmountFen)],
        ['入站线路号', hexByteCell(transit.entryLineCode)],
        ['出站线路号', hexByteCell(transit.exitLineCode)],
        ['进站交易金额', values.amountCell(transit.entryAmountFen)],
        ['进站钱包余额', values.balanceCell(transit.entryBalanceFen)],
        ['出闸交易金额', values.amountCell(transit.exitAmountFen)],
        if (transit.issuerCustom != null)
          ['发卡机构自定义', hexLower(transit.issuerCustom)],
      ];
    }
    if (record != null) {
      return [
        ['数据长度', '${record.raw.length} 字节'],
        ['原始数据', record.rawHex],
        ['说明', '记录长度不足或字段布局不符，未做推测解析，按原始数据展示'],
      ];
    }
    return [
      ['说明', '卡片未写入该记录（0x1A 记录 1）'],
    ];
  }

  List<List<String>> _liveBusRows(
    TUnionProcessRecord? record,
    BusTransitRecord? transit,
    ExpertValues values,
  ) {
    if (transit != null) {
      return [
        ['交易状态', codeName(transit.statusCode, transit.statusName)],
        ['上车城市代码', values.cityCell(transit.entryCityCode)],
        ['上车机构标识', hexLower(transit.entryAgencyId)],
        ['上车运营商代码', hexLower(transit.entryOperatorCode)],
        ['上车线路号', hexLower(transit.entryLineCode)],
        ['上车站点', hexLower(transit.entryStationCode)],
        ['上车车辆号', hexLower(transit.entryVehicleId)],
        ['上车终端编号', hexLower(transit.entryTerminalId)],
        ['上车时间', bcdTimeCell(transit.entryTime, transit.entryTimeBcd)],
        ['标注金额', values.amountCell(transit.annotateAmountFen)],
        ['方向标识', transit.directionName],
        ['下车城市代码', values.cityCell(transit.exitCityCode)],
        ['下车机构标识', hexLower(transit.exitAgencyId)],
        ['下车运营商代码', hexLower(transit.exitOperatorCode)],
        ['下车线路号', hexLower(transit.exitLineCode)],
        ['下车站点', hexLower(transit.exitStationCode)],
        ['下车车辆号', hexLower(transit.exitVehicleId)],
        ['下车终端编号', hexLower(transit.exitTerminalId)],
        ['下车时间', bcdTimeCell(transit.exitTime, transit.exitTimeBcd)],
        ['交易金额', values.amountCell(transit.transactionAmountFen)],
        ['乘车里程', intHexCell(transit.mileage)],
        if (transit.hasIssuerCustomData)
          ['发卡机构自定义', hexLower(transit.issuerCustomHex)],
      ];
    }
    if (record != null) {
      return [
        ['数据长度', '${record.raw.length} 字节'],
        ['原始数据', record.rawHex],
        ['说明', '记录长度不足或字段布局不符，未做推测解析，按原始数据展示'],
      ];
    }
    return [
      ['说明', '卡片未写入该记录（0x1A 记录 2）'],
    ];
  }

  List<List<String>> _liveCycleRows(
    TUnionTripRecord trip,
    ExpertValues values,
  ) => [
    ['交易类型', codeName(trip.typeCode, trip.typeName)],
    ['终端编号', trip.terminalId],
    ['应用分类码', codeName(trip.appTypeCode, trip.appTypeName)],
    ['线路', expertValue(trip.lineCode)],
    ['站点', expertValue(trip.stationCode)],
    ['运营代码', expertValue(trip.operatorCode)],
    ['交易金额', values.amountCell(trip.amountFen)],
    ['记录余额', values.balanceCell(trip.balanceFen)],
    ['交易日期时间', dateTimeDigits(trip.time)],
    ['受理方城市代码', values.cityCell(trip.cityCode)],
    ['受理方机构标识', hexLower(trip.acquirerId)],
  ];

  List<GalleryRecord> _liveCityUnionSections(
    AppDependencies app,
    int? walletFen,
  ) {
    final files = app.cityUnionFiles;
    final public = files.where((file) => file.sfi == 0x15).toList();
    final local = files.where((file) => file.sfi == 0x18).toList();
    final recharge = files.whereType<CjT331WalletRecharge>().toList();
    final foreign = files.whereType<CjT331WalletOfflineTransaction>().toList();
    final unparsed = files
        .whereType<CityUnionRawFileView>()
        .where((file) => file.sfi != 0x15 && file.sfi != 0x18)
        .toList();
    final cityCode = public.whereType<CjT331PublicInfo>().firstOrNull?.cityCode;
    final sections = <GalleryRecord>[
      {
        'title': '城市一卡通应用',
        'open': false,
        'rows': <List<String>>[
          if (walletFen != null)
            ['城市一卡通钱包余额', '${(walletFen / 100).toStringAsFixed(2)} 元'],
          ['已读取文件视图', '${files.length} 项'],
        ],
      },
    ];
    final publicView = public.firstOrNull;
    sections.add({
      'title': '0x15 · 公共应用基本信息文件',
      'open': false,
      'rows': publicView == null
          ? <List<String>>[
              ['说明', '未读取到公共应用基本信息文件（文件不存在或读取被拒）'],
            ]
          : <List<String>>[
              if (publicView.fields.isEmpty)
                ['说明', '未按标准解析（保留原始数据）']
              else
                for (final field in publicView.fields)
                  [field.name, cuFieldValue(field)],
              if (publicView.rawHex.isNotEmpty) ['原始数据', publicView.rawHex],
            ],
    });
    void addRecords(
      String title,
      String key,
      List<CityUnionFileView> records, {
      String? emptyHint,
    }) {
      if (records.isEmpty) {
        if (emptyHint != null) {
          sections.add({
            'title': title,
            'open': false,
            'rows': <List<String>>[
              ['说明', emptyHint],
            ],
          });
        }
        return;
      }
      for (var index = 0; index < records.length; index++) {
        final record = records[index];
        final station = _liveCuStationName(app, record, cityCode);
        sections.add({
          'title': '$title · $key ${index + 1}',
          'open': false,
          'rows': <List<String>>[
            if (record.fields.isEmpty)
              ['说明', record.errors.join('；')]
            else
              for (final field in record.fields)
                [field.name, cuFieldValue(field)],
            if (station != null) ['站点（终端解析）', station],
            if (record.rawHex.isNotEmpty) ['原始数据', record.rawHex],
          ],
        });
      }
    }

    addRecords(
      '0x18 · 电子钱包本地消费交易明细',
      '记录',
      local,
      emptyHint: '未读取到本地消费交易明细（文件不存在或记录未写入）',
    );
    addRecords(
      '电子钱包充值交易明细',
      '记录',
      recharge,
      emptyHint: '未读取到充值交易明细（文件不存在或记录未写入）',
    );
    addRecords(
      '电子钱包异地消费交易明细',
      '记录',
      foreign,
      emptyHint: '未读取到异地消费交易明细（文件不存在或记录未写入）',
    );
    addRecords('未解析记录', '记录', unparsed);
    return sections;
  }

  String? _liveCuStationName(
    AppDependencies app,
    CityUnionFileView record,
    String? cityCode,
  ) {
    if (record is! CityUnionWalletTransaction ||
        record.kind == CityUnionTransactionKind.recharge) {
      return null;
    }
    final identity = CityUnionLookupRules.identifyTerminal(record.terminalHex);
    if (identity == null) return null;
    return app.resolveCuStationName(
      identity.terminal,
      cityCode: identity.regionCode,
      decodedCarrierType: identity.carrier,
      transactionTime: CityUnionLookupRules.transactionTime(
        record.transactionDate,
        record.transactionTime,
      ),
      busLookupEnabled: true,
    );
  }

  List<(String, String)> _liveComplianceRows(AppDependencies app) {
    final parsed = app.parsedCard;
    if (parsed == null) {
      return const [('应用选择', '未发现受支持的交通应用')];
    }
    return [
      (
        '应用选择',
        parsed.selectedAidHex.isEmpty ? '未提供 AID' : parsed.selectedAidHex,
      ),
      ('解析器', parsed.parserName),
      ('余额读取', parsed.info.balanceFen == null ? '未读到余额' : '已读取'),
      ('交易文件', '${app.transactions.length} 条'),
      ('应用证据', '${app.applications.length} 项'),
      ('城市一卡通文件', '${app.cityUnionFiles.length} 个'),
      (
        '日期一致性',
        parsed.info.expireDate == null
            ? '未读取有效期'
            : '有效期 ${parsed.info.expireDate!.year}-${parsed.info.expireDate!.month}',
      ),
    ];
  }

  List<Widget> _liveRawSections(AppDependencies app) {
    final log = app.apduLog;
    final records = app.transitProcessRecords;
    return [
      _text(
        '以下为本次会话保留的原始命令、响应和应用记录。',
        role: GalleryTypography.caption,
        color: t.muted,
      ),
      _gap(12),
      _expand('live-expert:raw:apdu', 'APDU 命令 / 响应（${log.length} 项）', [
        _hexBox(log.isEmpty ? '本次读取未保留 APDU 详细日志。' : log.join('\n')),
      ], initiallyOpen: true),
      _gap(10),
      _expand(
        'live-expert:raw:process',
        '0x1A / 0x1E 原始记录（${records.length} 条）',
        [
          if (records.isEmpty)
            _text('本次读取未保留过程记录。', color: t.muted)
          else
            for (final record in records)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _hexBox(
                  'SFI 0x${record.sfi.toRadixString(16).padLeft(2, '0').toUpperCase()}'
                  ' · 记录 ${record.recordNumber + 1}\n${record.rawHex}',
                ),
              ),
        ],
        initiallyOpen: true,
      ),
    ];
  }
}
