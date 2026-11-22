import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VoiceDiaryApp());
}

class VoiceDiaryApp extends StatelessWidget {
  const VoiceDiaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Appunti a Voce',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00796B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 1,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 19,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Color(0xFF0F172A)),
        ),
      ),
      home: const DaysHomeScreen(),
    );
  }
}

// ==========================================
// 1. SCHERMATA PRINCIPALE: GIORNI CON NOTE
// ==========================================
class DaysHomeScreen extends StatefulWidget {
  const DaysHomeScreen({super.key});

  @override
  State<DaysHomeScreen> createState() => _DaysHomeScreenState();
}

class _DaysHomeScreenState extends State<DaysHomeScreen> with SingleTickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isServiceEnabled = false;
  bool _isSessionActive = false;
  bool _isSpeechListening = false;

  File? _activeFile;
  Timer? _sessionTimer;
  int _sessionSeconds = 0;
  int _sessionWordCount = 0;

  late AnimationController _pulseController;

  // Elenco file raggruppati per giorno: Chiave "YYYY-MM-DD" -> Lista di File
  Map<String, List<File>> _groupedDays = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _initSpeechEngine();
    _loadFilesFromStorage();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _sessionTimer?.cancel();
    _speech.stop();
    super.dispose();
  }

  Future<void> _initSpeechEngine() async {
    _isServiceEnabled = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (err) {
        if (_isSessionActive) {
          Future.delayed(const Duration(milliseconds: 600), _startListeningLoop);
        }
      },
    );
    if (mounted) setState(() {});
  }

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'listening') {
      setState(() => _isSpeechListening = true);
    } else if (status == 'notListening' || status == 'done') {
      setState(() => _isSpeechListening = false);
      if (_isSessionActive) {
        Future.delayed(const Duration(milliseconds: 300), _startListeningLoop);
      }
    }
  }

  Future<void> _loadFilesFromStorage() async {
    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final allFiles = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList();

    // Raggruppa per Giorno (Data di modifica del file)
    final Map<String, List<File>> groups = {};
    for (final file in allFiles) {
      final date = file.lastModifiedSync();
      final key = "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
      groups.putIfAbsent(key, () => []).add(file);
    }

    // Ordina le note dentro ogni giorno (dalla più recente alla più vecchia)
    groups.forEach((key, list) {
      list.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    });

    // Ordina i giorni in modo decrescente (Oggi in cima)
    final sortedKeys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final Map<String, List<File>> sortedGroups = {
      for (final k in sortedKeys) k: groups[k]!,
    };

    if (mounted) {
      setState(() {
        _groupedDays = sortedGroups;
        _isLoading = false;
      });
    }
  }

  // --- AVVIO E ARRESTO REGISTRAZIONE ---
  Future<void> _toggleSession() async {
    if (_isSessionActive) {
      await _stopSession();
    } else {
      await _startSession();
    }
  }

  Future<void> _startSession() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permesso microfono necessario per registrare.')),
        );
      }
      return;
    }

    if (!_isServiceEnabled) {
      await _initSpeechEngine();
      if (!_isServiceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Motore vocale non pronto sul telefono.')),
          );
        }
        return;
      }
    }

    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _activeFile = File('${directory.path}/nota_$timestamp.txt');
    await _activeFile!.writeAsString(
      "--- NOTA VOCALE: ${DateTime.now().toString().split('.')[0]} ---\n\n",
      flush: true,
    );

    setState(() {
      _isSessionActive = true;
      _sessionSeconds = 0;
      _sessionWordCount = 0;
    });

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isSessionActive) {
        setState(() => _sessionSeconds++);
      }
    });

    _startListeningLoop();
  }

  Future<void> _stopSession() async {
    _sessionTimer?.cancel();
    _sessionTimer = null;
    _isSessionActive = false;
    await _speech.stop();

    if (_activeFile != null && await _activeFile!.exists()) {
      await _activeFile!.writeAsString(
        "\n--- FINE NOTA ---\n",
        mode: FileMode.append,
        flush: true,
      );
    }

    setState(() {
      _isSpeechListening = false;
    });

    // Ricarica la lista giorni per mostrare subito la nuova nota
    await _loadFilesFromStorage();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nota vocale salvata con successo nel giorno di oggi!')),
      );
    }
  }

  void _startListeningLoop() {
    if (!_isSessionActive || _speech.isListening) return;

    _speech.listen(
      localeId: 'it_IT',
      listenMode: stt.ListenMode.dictation,
      listenFor: const Duration(hours: 2),
      pauseFor: const Duration(seconds: 5),
      partialResults: true,
      onResult: (result) {
        if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
          _appendPhraseToDisk(result.recognizedWords.trim());
        }
      },
    );
  }

  Future<void> _appendPhraseToDisk(String phrase) async {
    if (_activeFile == null) return;

    final now = DateTime.now();
    final timeStr = "[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}]";
    final line = "$timeStr $phrase\n\n";

    await _activeFile!.writeAsString(line, mode: FileMode.append, flush: true);
    final words = phrase.split(RegExp(r'\s+')).length;

    if (mounted) {
      setState(() {
        _sessionWordCount += words;
      });
    }
  }

  String _formatDuration(int seconds) {
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatDayLabel(String dateKey) {
    final parts = dateKey.split('-');
    if (parts.length != 3) return dateKey;

    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    final day = int.parse(parts[2]);
    final date = DateTime(year, month, day);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(date).inDays;

    final months = [
      '', 'Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno',
      'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre'
    ];
    final weekdays = [
      '', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato', 'Domenica'
    ];

    if (diff == 0) {
      return "Oggi, ${day} ${months[month]}";
    } else if (diff == 1) {
      return "Ieri, ${day} ${months[month]}";
    } else {
      return "${weekdays[date.weekday]} ${day} ${months[month]} ${year}";
    }
  }

  int _calculateDaySize(List<File> files) {
    int total = 0;
    for (final f in files) {
      if (f.existsSync()) total += f.lengthSync();
    }
    return total;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Appunti a Voce'),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _groupedDays.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE0F2F1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.mic, size: 48, color: Color(0xFF00796B)),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Nessun appunto registrato',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Premi il pulsante in basso per registrare il tuo primo appunto vocale. Verrà organizzato automaticamente per giorno.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: Colors.grey.shade600, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                    itemCount: _groupedDays.keys.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final dayKey = _groupedDays.keys.elementAt(index);
                      final dayFiles = _groupedDays[dayKey]!;
                      final dayTitle = _formatDayLabel(dayKey);
                      final totalSize = _calculateDaySize(dayFiles);

                      return InkWell(
                        onTap: () async {
                          // Apre la pagina dedicata a quel giorno
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DayDetailScreen(
                                dayKey: dayKey,
                                dayTitle: dayTitle,
                                initialFiles: dayFiles,
                              ),
                            ),
                          );
                          // Ricarica la lista al ritorno se sono state cancellate note
                          _loadFilesFromStorage();
                        },
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: Colors.grey.shade200),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.02),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE0F2F1),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Icon(Icons.calendar_today_rounded, color: Color(0xFF00796B), size: 24),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      dayTitle,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF0F172A),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Text(
                                          '${dayFiles.length} ${dayFiles.length == 1 ? "nota" : "note"}',
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF00796B),
                                          ),
                                        ),
                                        Text(
                                          ' • ${_formatBytes(totalSize)}',
                                          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400, size: 28),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),

      // BARRA FISSA DI REGISTRAZIONE IN BASSO
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isSessionActive)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          return Container(
                            width: 10,
                            height: 10,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.red.withOpacity(_pulseController.value * 0.7 + 0.3),
                            ),
                          );
                        },
                      ),
                      Text(
                        'REGISTRAZIONE IN CORSO • ${_formatDuration(_sessionSeconds)} ($_sessionWordCount parole)',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFC62828),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: _toggleSession,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isSessionActive ? const Color(0xFFC62828) : const Color(0xFF00796B),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: Icon(_isSessionActive ? Icons.stop_rounded : Icons.mic_rounded, size: 24),
                  label: Text(
                    _isSessionActive ? 'Arresta e Salva in Oggi' : 'Avvia Nuova Registrazione',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 2. PAGINA DEL SINGOLO GIORNO CON NOTE
// ==========================================
class DayDetailScreen extends StatefulWidget {
  final String dayKey;
  final String dayTitle;
  final List<File> initialFiles;

  const DayDetailScreen({
    super.key,
    required this.dayKey,
    required this.dayTitle,
    required this.initialFiles,
  });

  @override
  State<DayDetailScreen> createState() => _DayDetailScreenState();
}

class _DayDetailScreenState extends State<DayDetailScreen> {
  late List<File> _files;
  final Set<File> _selectedFiles = {};
  bool _isSelectionMode = false;

  @override
  void initState() {
    super.initState();
    _files = List.from(widget.initialFiles);
  }

  void _toggleSelection(File file) {
    setState(() {
      if (_selectedFiles.contains(file)) {
        _selectedFiles.remove(file);
        if (_selectedFiles.isEmpty) _isSelectionMode = false;
      } else {
        _selectedFiles.add(file);
        _isSelectionMode = true;
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_selectedFiles.length == _files.length) {
        _selectedFiles.clear();
        _isSelectionMode = false;
      } else {
        _selectedFiles.clear();
        _selectedFiles.addAll(_files);
        _isSelectionMode = true;
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectedFiles.clear();
      _isSelectionMode = false;
    });
  }

  // Condividi note selezionate (Multi-invio WhatsApp / Email / etc.)
  void _shareSelected() {
    if (_selectedFiles.isEmpty) return;

    final xFiles = _selectedFiles.map((f) => XFile(f.path)).toList();
    Share.shareXFiles(
      xFiles,
      subject: '${widget.dayTitle} (${_selectedFiles.length} note)',
      text: 'In allegato le note vocali di ${widget.dayTitle}.',
    );
  }

  // Elimina note selezionate
  Future<void> _deleteSelected() async {
    final count = _selectedFiles.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Elimina Note'),
        content: Text('Sei sicuro di voler eliminare $count note da questa giornata?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      for (final file in _selectedFiles) {
        if (await file.exists()) {
          await file.delete();
        }
        _files.remove(file);
      }
      _selectedFiles.clear();
      _isSelectionMode = false;
      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count note eliminate.')),
        );
      }
    }
  }

  // Condivisione singola nota
  void _showShareMenuForSingle(File file) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Condividi Nota',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: const Color(0xFF25D366).withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.chat_bubble_outline, color: Color(0xFF25D366)),
                ),
                title: const Text('Invia tramite WhatsApp', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Invia il file .txt nella chat', style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  Share.shareXFiles([XFile(file.path)], text: 'Nota vocale di ${widget.dayTitle}');
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.blue.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.email_outlined, color: Colors.blue),
                ),
                title: const Text('Invia tramite Email', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Allega la nota a una mail', style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  Share.shareXFiles([XFile(file.path)], subject: 'Nota ${widget.dayTitle}', text: 'In allegato il file di testo.');
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.red.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.picture_as_pdf_outlined, color: Colors.red),
                ),
                title: const Text('Esporta come PDF', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Genera documento PDF e condividilo', style: TextStyle(fontSize: 12)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _exportSinglePdf(file);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.grey.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.copy, color: Colors.grey),
                ),
                title: const Text('Copia Testo', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final text = await file.readAsString();
                  await Clipboard.setData(ClipboardData(text: text));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Testo copiato!')));
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportSinglePdf(File txtFile) async {
    final content = await txtFile.readAsString();
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) => [
          pw.Header(level: 0, child: pw.Text("Nota Vocale - ${widget.dayTitle}", style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold))),
          pw.SizedBox(height: 12),
          pw.Paragraph(text: content, style: const pw.TextStyle(fontSize: 12, lineSpacing: 2)),
        ],
      ),
    );

    final pdfPath = txtFile.path.replaceAll('.txt', '.pdf');
    final pdfFile = File(pdfPath);
    await pdfFile.writeAsBytes(await pdf.save());

    Share.shareXFiles([XFile(pdfFile.path)], subject: 'Nota PDF');
  }

  // Visualizza contenuto nota
  Future<void> _viewFile(File file) async {
    if (!await file.exists()) return;
    final content = await file.readAsString();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, controller) => Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Testo della Nota', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              Text(file.path.split('/').last, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const Divider(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  controller: controller,
                  child: SelectableText(
                    content.isEmpty ? "Nessun testo registrato." : content,
                    style: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFF1E293B)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime date) {
    return "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}";
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _files.isNotEmpty && _selectedFiles.length == _files.length;

    return Scaffold(
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Annulla selezione',
                onPressed: _exitSelectionMode,
              )
            : const BackButton(),
        title: Text(
          _isSelectionMode ? '${_selectedFiles.length} selezionate' : widget.dayTitle,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          if (_files.isNotEmpty)
            IconButton(
              icon: Icon(allSelected ? Icons.select_all : Icons.checklist_rtl_rounded),
              tooltip: allSelected ? 'Deseleziona tutte' : 'Seleziona tutte',
              onPressed: _selectAll,
            ),
        ],
      ),
      body: SafeArea(
        child: _files.isEmpty
            ? const Center(
                child: Text('Tutte le note di questa giornata sono state eliminate.'),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                itemCount: _files.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final file = _files[index];
                  final isSelected = _selectedFiles.contains(file);
                  final modified = file.lastModifiedSync();
                  final timeStr = _formatTime(modified);
                  final sizeKb = _formatBytes(file.existsSync() ? file.lengthSync() : 0);

                  return Container(
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFFE0F2F1) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? const Color(0xFF00796B) : Colors.grey.shade200,
                        width: isSelected ? 1.5 : 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.02),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      onLongPress: () => _toggleSelection(file),
                      onTap: () {
                        if (_isSelectionMode) {
                          _toggleSelection(file);
                        } else {
                          _viewFile(file);
                        }
                      },
                      leading: _isSelectionMode
                          ? Checkbox(
                              value: isSelected,
                              activeColor: const Color(0xFF00796B),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              onChanged: (_) => _toggleSelection(file),
                            )
                          : Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE0F2F1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.mic_none_rounded, color: Color(0xFF00796B), size: 22),
                            ),
                      title: Text(
                        'Registrazione delle ore $timeStr',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: isSelected ? const Color(0xFF004D40) : const Color(0xFF0F172A),
                        ),
                      ),
                      subtitle: Text(
                        '$sizeKb • Tocca per leggere il testo',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                      trailing: _isSelectionMode
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.share_outlined, color: Color(0xFF00796B)),
                                  tooltip: 'Condividi (WhatsApp / Email)',
                                  onPressed: () => _showShareMenuForSingle(file),
                                ),
                              ],
                            ),
                    ),
                  );
                },
              ),
      ),

      // BARRA AZIONI MULTIPLE IN BASSO (Compare quando selezioni note)
      bottomNavigationBar: _selectedFiles.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 16,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _deleteSelected,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFE53935),
                          side: const BorderSide(color: Color(0xFFE53935), width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        label: Text('Elimina (${_selectedFiles.length})'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _shareSelected,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF00796B),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: const Icon(Icons.share_outlined, size: 20),
                        label: Text('Invia (${_selectedFiles.length})'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
