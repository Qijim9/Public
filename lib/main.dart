import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '打工与回国基金助手',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.light,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// 统一数据模型
class IncomeRecord {
  final String id;
  final DateTime date;
  final bool isJob; // true为打工(工时)，false为其他收入(如零花钱)
  final double? startHour; // 打工开始时间(24h制)
  final double? endHour;   // 打工结束时间
  final int amount;        // 金额(打工时为自定义时薪，其他收入时为总金额)
  final String note;       // 备注

  IncomeRecord({
    required this.id,
    required this.date,
    required this.isJob,
    this.startHour,
    this.endHour,
    required this.amount,
    required this.note,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'date': date.toIso8601String(),
    'isJob': isJob,
    'startHour': startHour,
    'endHour': endHour,
    'amount': amount,
    'note': note,
  };

  factory IncomeRecord.fromJson(Map<String, dynamic> json) => IncomeRecord(
    id: json['id'],
    date: DateTime.parse(json['date']),
    isJob: json['isJob'],
    startHour: json['startHour']?.toDouble(),
    endHour: json['endHour']?.toDouble(),
    amount: json['amount'],
    note: json['note'] ?? '',
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<IncomeRecord> _records = [];
  int _defaultHourlyWage = 10100; // 韩国基础时薪
  double _exchangeRate = 0.0053; // 默认汇率 (韩币 KRW -> 人民币 CNY)
  DateTime _selectedMonth = DateTime.now();
  int _salaryDay = 5; // 默认每月5号发工资
  DateTime _targetDate = DateTime(2027, 1, 5); // 默认1月5号回国

  @override
  void initState() {
    super.initState();
    _loadData();
    _fetchLiveExchangeRate();
  }

  // 加载本地存储
  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _defaultHourlyWage = prefs.getInt('defaultHourlyWage') ?? 10100;
      _salaryDay = prefs.getInt('salaryDay') ?? 5;
      _exchangeRate = prefs.getDouble('exchangeRate') ?? 0.0053;
      
      final targetStr = prefs.getString('targetDate');
      if (targetStr != null) {
        _targetDate = DateTime.parse(targetStr);
      }

      final recordsStr = prefs.getString('records');
      if (recordsStr != null) {
        final List<dynamic> decoded = jsonDecode(recordsStr);
        _records = decoded.map((item) => IncomeRecord.fromJson(item)).toList();
      }
    });
  }

  // 保存数据到本地
  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('defaultHourlyWage', _defaultHourlyWage);
    await prefs.setInt('salaryDay', _salaryDay);
    await prefs.setDouble('exchangeRate', _exchangeRate);
    await prefs.setString('targetDate', _targetDate.toIso8601String());
    
    final recordsStr = jsonEncode(_records.map((r) => r.toJson()).toList());
    await prefs.setString('records', recordsStr);
  }

  // 异步获取实时汇率 (采用免费无需key接口)
  Future<void> _fetchLiveExchangeRate() async {
    try {
      final response = await http.get(Uri.parse('https://open.er-api.com/v6/latest/KRW'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final rate = data['rates']['CNY'];
        if (rate != null) {
          setState(() {
            _exchangeRate = rate.toDouble();
          });
          _saveData();
        }
      }
    } catch (_) {
      // 联网失败则自动静默使用上一次成功保存的本地汇率
    }
  }

  // 计算打工单次总收入
  int _calculateJobPay(IncomeRecord r) {
    if (!r.isJob) return r.amount;
    double hours = (r.endHour ?? 0) - (r.startHour ?? 0);
    return (hours * r.amount).round();
  }

  // 核心算法：1. 计算指定周期的工资日能拿到的总额
  int _getPaydayEarnings() {
    // 假设工资日是5号，账期是上月6号到本月5号
    DateTime startOfPeriod = DateTime(_selectedMonth.year, _selectedMonth.month - 1, _salaryDay + 1);
    DateTime endOfPeriod = DateTime(_selectedMonth.year, _selectedMonth.month, _salaryDay);

    int total = 0;
    for (var r in _records) {
      if (r.date.isAfter(startOfPeriod.subtract(const Duration(days: 1))) && 
          r.date.isBefore(endOfPeriod.add(const Duration(days: 1)))) {
        total += _calculateJobPay(r);
      }
    }
    return total;
  }

  // 核心算法：2. 计算直到“回国日”为止的总收入预测
  int _getForecastToTargetDate() {
    int earnedSoFar = 0;
    for (var r in _records) {
      if (r.date.isBefore(_targetDate.add(const Duration(days: 1)))) {
        earnedSoFar += _calculateJobPay(r);
      }
    }
    return earnedSoFar;
  }

  // 添加/编辑记录
  void _addOrUpdateRecord(IncomeRecord record) {
    setState(() {
      _records.removeWhere((r) => r.id == record.id);
      _records.add(record);
    });
    _saveData();
  }

  // 删除记录
  void _deleteRecord(String id) {
    setState(() {
      _records.removeWhere((r) => r.id == id);
    });
    _saveData();
  }

  @override
  Widget build(BuildContext context) {
    final curMonthRecords = _records.where((r) => r.date.month == _selectedMonth.month && r.date.year == _selectedMonth.year).toList();
    final totalPaydayKrw = _getPaydayEarnings();
    final totalPaydayCny = totalPaydayKrw * _exchangeRate;

    final targetForecastKrw = _getForecastToTargetDate();
    final targetForecastCny = targetForecastKrw * _exchangeRate;

    return Scaffold(
      appBar: AppBar(
        title: const Text('打工与回国基金记账'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部的亮眼双币种看板
          Container(
            padding: const EdgeInsets.all(16.0),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('工资日预测 (每月 $_salaryDay 号)', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                        const SizedBox(height: 4),
                        Text('₩ ${totalPaydayKrw.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal)),
                        Text('≈ ¥ ${totalPaydayCny.toStringAsFixed(2)}', style: const TextStyle(fontSize: 14, color: Colors.blueGrey)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('至回国日预测 (${_targetDate.month}/${_targetDate.day})', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
                        const SizedBox(height: 4),
                        Text('₩ ${targetForecastKrw.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepOrange)),
                        Text('≈ ¥ ${targetForecastCny.toStringAsFixed(2)}', style: const TextStyle(fontSize: 14, color: Colors.blueGrey)),
                      ],
                    ),
                  ],
                ),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('实时汇率: 1 KRW = ${_exchangeRate.toStringAsFixed(6)} CNY', style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                    TextButton(onPressed: _fetchLiveExchangeRate, child: const Text('刷新汇率', style: TextStyle(fontSize: 12))),
                  ],
                )
              ],
            ),
          ),
          // 月份切换
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios),
                  onPressed: () => setState(() => _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1)),
                ),
                Text('${_selectedMonth.year}年 ${_selectedMonth.month}月', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios),
                  onPressed: () => setState(() => _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1)),
                ),
              ],
            ),
          ),
          // 列表显示本月所有记录
          Expanded(
            child: curMonthRecords.isEmpty
                ? const Center(child: Text('这个月还没有记录哦，点击下方 + 开始记录吧！'))
                : ListView.builder(
                    itemCount: curMonthRecords.length,
                    itemBuilder: (context, index) {
                      final r = curMonthRecords[index];
                      final pay = _calculateJobPay(r);
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: r.isJob ? Colors.teal[100] : Colors.orange[100],
                            child: Icon(r.isJob ? Icons.work : Icons.attach_money, color: r.isJob ? Colors.teal : Colors.orange),
                          ),
                          title: Text(r.isJob 
                              ? '打工: ${(r.endHour! - r.startHour!).toStringAsFixed(1)} 小时 (${_formatTime(r.startHour!)} - ${_formatTime(r.endHour!)})' 
                              : '其他收入: ${r.note}'),
                          subtitle: Text('${r.date.month}月${r.date.day}日${r.isJob ? " (时薪: ₩${r.amount})" : ""}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('₩${pay.toString()}', style: const TextStyle(fontWeight: FontWeight.bold)),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.redAccent),
                                onPressed: () => _deleteRecord(r.id),
                              )
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddRecordBottomSheet(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  String _formatTime(double value) {
    int hour = value.floor();
    int minute = ((value - hour) * 60).round();
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  // 弹窗：添加记录
  void _showAddRecordBottomSheet(BuildContext context) {
    DateTime selectedDate = DateTime.now();
    bool isJob = true;
    RangeValues timeRange = const RangeValues(9.0, 18.0); // 默认 09:00 - 18:00
    final amountController = TextEditingController(text: _defaultHourlyWage.toString());
    final noteController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            double workedHours = timeRange.end - timeRange.start;
            int calculatedPay = isJob ? (workedHours * (int.tryParse(amountController.text) ?? 0)).round() : (int.tryParse(amountController.text) ?? 0);

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isJob ? '添加打工工时' : '添加其他收入', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    // 选择类型
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('打工工时'),
                          selected: isJob,
                          onSelected: (val) => setModalState(() {
                            isJob = true;
                            amountController.text = _defaultHourlyWage.toString();
                          }),
                        ),
                        const SizedBox(width: 12),
                        ChoiceChip(
                          label: const Text('零花钱/其他收入'),
                          selected: !isJob,
                          onSelected: (val) => setModalState(() {
                            isJob = false;
                            amountController.text = '';
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // 选择日期
                    ListTile(
                      leading: const Icon(Icons.calendar_month),
                      title: Text('日期: ${selectedDate.year}-${selectedDate.month}-${selectedDate.day}'),
                      trailing: const Icon(Icons.edit),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime(2025),
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          setModalState(() => selectedDate = picked);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    if (isJob) ...[
                      // 滑动选择工作时间
                      Text('滑动调整上班时间段 (当前: ${_formatTime(timeRange.start)} 到 ${_formatTime(timeRange.end)})', style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      RangeSlider(
                        values: timeRange,
                        min: 0.0,
                        max: 24.0,
                        divisions: 48, // 每半小时为一个刻度
                        labels: RangeLabels(
                          _formatTime(timeRange.start),
                          _formatTime(timeRange.end),
                        ),
                        onChanged: (values) {
                          if (values.end - values.start >= 0.5) { // 限制最少打工半小时
                            setModalState(() => timeRange = values);
                          }
                        },
                      ),
                      Text('总计时间: ${workedHours.toStringAsFixed(1)} 小时', style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                    ],
                    // 金额/时薪输入
                    TextField(
                      controller: amountController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: isJob ? '自定义每小时时薪(KRW)' : '输入总金额(KRW)',
                        border: const OutlineInputBorder(),
                        prefixText: '₩ ',
                      ),
                      onChanged: (_) => setModalState(() {}),
                    ),
                    const SizedBox(height: 16),
                    // 备注输入
                    TextField(
                      controller: noteController,
                      decoration: InputDecoration(
                        labelText: isJob ? '备注（如：周末烤肉店）' : '来源（如：爸妈零花钱）',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // 动态显示总价
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: Colors.grey[100],
                      child: Text(
                        '本次预计赚取: ₩ ${calculatedPay.toString()} (≈ ¥ ${(calculatedPay * _exchangeRate).toStringAsFixed(2)})',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 保存按钮
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      onPressed: () {
                        final amt = int.tryParse(amountController.text) ?? 0;
                        if (amt <= 0) return;

                        final newRec = IncomeRecord(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          date: selectedDate,
                          isJob: isJob,
                          startHour: isJob ? timeRange.start : null,
                          endHour: isJob ? timeRange.end : null,
                          amount: amt,
                          note: noteController.text,
                        );

                        _addOrUpdateRecord(newRec);
                        Navigator.pop(context);
                      },
                      child: const Text('保存记录'),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // 弹窗：系统全局设置
  void _showSettingsDialog() {
    final wageController = TextEditingController(text: _defaultHourlyWage.toString());
    final salaryDayController = TextEditingController(text: _salaryDay.toString());
    DateTime localTargetDate = _targetDate;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('全局系统配置'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: wageController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '默认时薪 (₩ KRW/小时)'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: salaryDayController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '工资发放日 (几号结算)'),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      title: Text('回国倒计时目标日:\n${localTargetDate.year}-${localTargetDate.month}-${localTargetDate.day}'),
                      trailing: const Icon(Icons.edit),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: localTargetDate,
                          firstDate: DateTime.now(),
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          setDialogState(() => localTargetDate = picked);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _defaultHourlyWage = int.tryParse(wageController.text) ?? _defaultHourlyWage;
                      _salaryDay = int.tryParse(salaryDayController.text) ?? _salaryDay;
                      _targetDate = localTargetDate;
                    });
                    _saveData();
                    Navigator.pop(context);
                  },
                  child: const Text('保存并应用'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
