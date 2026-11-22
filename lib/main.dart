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
  runApp(const VoiceTranscriberApp());
}

class VoiceTranscriberApp extends StatelessWidget {
  const VoiceTranscriberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Appunti a Voce',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00796B), // Teal elegante
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F9FA),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 1,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFF1E293B),
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Color(0xFF1E293B)),
        ),
      ),
      home: const TranscriberScreen(),
    );
  }
}

class TranscriberScreen extends StatefulWidget {
  const TranscriberScreen({super.key});

  @override
  State<TranscriberScreen> createState() => _TranscriberScreenState();
}

class _TranscriberScreenState extends State<TranscriberScreen> with SingleTickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isServiceEnabled = false;
  bool _isSessionActive = false;
  bool _isSpeechListening = false;

  File? _activeFile;
  int _totalBytesWritten = 0;
  int _totalWordCount = 0;

  Timer? _sessionTimer;
  int _sessionSeconds = 0;

  String _currentSpokenSentence = "";
  final List<String> _recentLog = [];

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _initSpeechEngine();
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
      "--- APPUNTI VOCALI: ${DateTime.now().toString().split('.')[0]} ---\n\n",
      flush: true,
    );

    setState(() {
      _isSessionActive = true;
      _sessionSeconds = 0;
      _totalBytesWritten = _activeFile!.lengthSync();
      _totalWordCount = 0;
      _currentSpokenSentence = "";
      _recentLog.clear();
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
        "\n--- FINE NOTA: ${DateTime.now().toString().split('.')[0]} ---\n",
        mode: FileMode.append,
        flush: true,
      );
      _totalBytesWritten = _activeFile!.lengthSync();
    }

    setState(() {
      _isSpeechListening = false;
      _currentSpokenSentence = "";
    });

    if (mounted && _activeFile != null) {
      _showShareBottomSheet(_activeFile!);
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
        setState(() {
          _currentSpokenSentence = result.recognizedWords;
        });

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

    setState(() {
      _totalBytesWritten = _activeFile!.lengthSync();
      _totalWordCount += words;
      _currentSpokenSentence = "";

      _recentLog.insert(0, "$timeStr $phrase");
      if (_recentLog.length > 20) {
        _recentLog.removeLast();
      }
    });
  }

  // --- MODALE DI CONDIVISIONE ---
  void _showShareBottomSheet(File file) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE0F2F1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.share, color: Color(0xFF00796B)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Condividi Trascrizione',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                        ),
                        Text(
                          '${file.path.split('/').last} • ${_formatBytes(file.lengthSync())}',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // WhatsApp
              _buildShareOption(
                icon: Icons.chat_bubble_outline,
                iconColor: const Color(0xFF25D366),
                title: 'Invia tramite WhatsApp',
                subtitle: 'Condividi il file .txt con chat o gruppi',
                onTap: () {
                  Navigator.pop(ctx);
                  Share.shareXFiles(
                    [XFile(file.path)],
                    text: 'Trascrizione appunti vocali.',
                  );
                },
              ),

              const SizedBox(height: 10),

              // Email
              _buildShareOption(
                icon: Icons.email_outlined,
                iconColor: const Color(0xFF1976D2),
                title: 'Invia tramite Email',
                subtitle: 'Allega il file .txt a una nuova email',
                onTap: () {
                  Navigator.pop(ctx);
                  Share.shareXFiles(
                    [XFile(file.path)],
                    subject: 'Trascrizione Vocale: ${DateTime.now().toString().split('.')[0]}',
                    text: 'In allegato il file di testo con la trascrizione della registrazione.',
                  );
                },
              ),

              const SizedBox(height: 10),

              // PDF
              _buildShareOption(
                icon: Icons.picture_as_pdf_outlined,
                iconColor: const Color(0xFFD32F2F),
                title: 'Invia come documento PDF',
                subtitle: 'Genera documento impaginato e condividilo',
                onTap: () async {
                  Navigator.pop(ctx);
                  await _shareAsPdf(file);
                },
              ),

              const SizedBox(height: 10),

              // Copia testo
              _buildShareOption(
                icon: Icons.copy_rounded,
                iconColor: const Color(0xFF546E7A),
                title: 'Copia Testo negli Appunti',
                subtitle: 'Copia il testo completo per incollarlo ovunque',
                onTap: () async {
                  Navigator.pop(ctx);
                  final text = await file.readAsString();
                  await Clipboard.setData(ClipboardData(text: text));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Testo copiato negli appunti!')),
                    );
                  }
                },
              ),

              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Chiudi'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShareOption({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade200),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B))),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Future<void> _shareAsPdf(File txtFile) async {
    final content = await txtFile.readAsString();
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) => [
          pw.Header(
            level: 0,
            child: pw.Text("Appunti Vocali", style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          ),
          pw.Text("Data: ${DateTime.now().toString().split('.')[0]}", style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.SizedBox(height: 12),
          pw.Paragraph(
            text: content,
            style: const pw.TextStyle(fontSize: 12, lineSpacing: 2),
          ),
        ],
      ),
    );

    final pdfPath = txtFile.path.replaceAll('.txt', '.pdf');
    final pdfFile = File(pdfPath);
    await pdfFile.writeAsBytes(await pdf.save());

    Share.shareXFiles(
      [XFile(pdfFile.path)],
      subject: 'Appunti Vocali PDF',
      text: 'In allegato il file PDF generato.',
    );
  }

  Future<void> _viewSavedFile(File file) async {
    if (!await file.exists()) return;
    final content = await file.readAsString();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, controller) => Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Anteprima Testo', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              Text(
                '${file.path.split('/').last} • ${_formatBytes(file.lengthSync())}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  controller: controller,
                  child: SelectableText(
                    content.isEmpty ? "Nessun testo registrato." : content,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openArchiveScreen() async {
    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final files = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArchiveScreen(
          files: files,
          onShare: _showShareBottomSheet,
          onView: _viewSavedFile,
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: 'Archivio Trascrizioni',
            onPressed: _openArchiveScreen,
          ),
          if (_activeFile != null)
            IconButton(
              icon: const Icon(Icons.remove_red_eye_outlined),
              tooltip: 'Visualizza Testo Completo',
              onPressed: () => _viewSavedFile(_activeFile!),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Scheda Statistiche
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.03),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildStatItem('Durata', _formatDuration(_sessionSeconds), Icons.timer_outlined, const Color(0xFF00796B)),
                    _buildDivider(),
                    _buildStatItem('Occupazione', _formatBytes(_totalBytesWritten), Icons.storage_outlined, const Color(0xFF1976D2)),
                    _buildDivider(),
                    _buildStatItem('Parole', '$_totalWordCount', Icons.text_snippet_outlined, const Color(0xFFE65100)),
                  ],
                ),
              ),
            ),

            // Card Stato Microfono / Parla ora
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _isSessionActive ? const Color(0xFFE0F2F1) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isSessionActive ? const Color(0xFF00796B) : Colors.grey.shade200,
                    width: _isSessionActive ? 1.5 : 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.02),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_isSessionActive)
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
                          )
                        else
                          Icon(Icons.mic_off, size: 16, color: Colors.grey.shade500),
                        const SizedBox(width: 4),
                        Text(
                          _isSessionActive
                              ? (_isSpeechListening ? "ASCOLTO CONTINUO ATTIVO" : "IN ATTESA DI VOCE...")
                              : "MICROFONO IN PAUSA",
                          style: TextStyle(
                            fontSize: 12,
                            letterSpacing: 0.8,
                            fontWeight: FontWeight.bold,
                            color: _isSessionActive ? const Color(0xFF004D40) : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _currentSpokenSentence.isNotEmpty
                          ? _currentSpokenSentence
                          : (_isSessionActive
                              ? "Parla adesso: ogni parola viene salvata istantaneamente su file..."
                              : "Premi il pulsante in basso per iniziare la registrazione."),
                      style: TextStyle(
                        fontSize: 15,
                        fontStyle: _currentSpokenSentence.isEmpty ? FontStyle.italic : FontStyle.normal,
                        color: _currentSpokenSentence.isNotEmpty ? const Color(0xFF0F172A) : Colors.grey.shade700,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Card Ultime Frasi Scritte
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.02),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Ultime frasi scritte su disco',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF334155),
                              ),
                            ),
                            if (_recentLog.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${_recentLog.length} voci',
                                  style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: _recentLog.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.notes_rounded, size: 40, color: Colors.grey.shade300),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Nessuna frase ancora trascritta.\nIl testo comparirà qui man mano che parli.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: Colors.grey.shade500, fontSize: 13, height: 1.4),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                itemCount: _recentLog.length,
                                separatorBuilder: (_, __) => Divider(height: 12, color: Colors.grey.shade100),
                                itemBuilder: (context, index) {
                                  return Text(
                                    _recentLog[index],
                                    style: const TextStyle(
                                      fontSize: 13,
                                      height: 1.4,
                                      color: Color(0xFF1E293B),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),

      // BARRA AZIONI FISSA IN BASSO (Completamente priva di sovrapposizioni)
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
              // Pulsante Principale di Registrazione (Grande e chiaro)
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
                  icon: Icon(_isSessionActive ? Icons.stop_rounded : Icons.fiber_manual_record, size: 24),
                  label: Text(
                    _isSessionActive ? 'Arresta e Salva' : 'Avvia Registrazione Continua',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              // Pulsante Condividi (visibile solo se non si sta registrando ed esiste già una nota)
              if (!_isSessionActive && _activeFile != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: () => _showShareBottomSheet(_activeFile!),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF00796B),
                      side: const BorderSide(color: Color(0xFF00796B), width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: const Icon(Icons.share_outlined, size: 20),
                    label: const Text(
                      'Condividi Ultima Nota (WhatsApp / Email)',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      width: 1,
      height: 36,
      color: Colors.grey.shade200,
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, Color iconColor) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Color(0xFF0F172A),
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey.shade500,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// --- ARCHIVIO REGISTRAZIONI ---
class ArchiveScreen extends StatefulWidget {
  final List<File> files;
  final Function(File) onShare;
  final Function(File) onView;

  const ArchiveScreen({
    super.key,
    required this.files,
    required this.onShare,
    required this.onView,
  });

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  late List<File> _fileList;

  @override
  void initState() {
    super.initState();
    _fileList = List.from(widget.files);
  }

  void _deleteFile(File file) async {
    await file.delete();
    setState(() {
      _fileList.remove(file);
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nota eliminata.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Archivio Note Vocali'),
      ),
      body: SafeArea(
        child: _fileList.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open, size: 48, color: Colors.grey.shade300),
                    const SizedBox(height: 12),
                    Text(
                      'Nessuna nota salvata nell\'archivio.',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                    ),
                  ],
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _fileList.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final file = _fileList[index];
                  final date = file.lastModifiedSync();
                  final dateStr =
                      "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";
                  final sizeKb = (file.lengthSync() / 1024).toStringAsFixed(1);

                  return Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.02),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      leading: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE0F2F1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.description_outlined, color: Color(0xFF00796B)),
                      ),
                      title: Text(
                        file.path.split('/').last,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B)),
                      ),
                      subtitle: Text('$dateStr • $sizeKb KB', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                      onTap: () => widget.onView(file),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.share_outlined, color: Color(0xFF00796B)),
                            tooltip: 'Condividi (WhatsApp / Email)',
                            onPressed: () => widget.onShare(file),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Color(0xFFE53935)),
                            tooltip: 'Elimina',
                            onPressed: () => _deleteFile(file),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
