import 'dart:io';
import 'package:flutter/material.dart';
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
      title: 'Voice to File',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
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

class _TranscriberScreenState extends State<TranscriberScreen> {
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _transcribedText = "";
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
  }

  // Inizia o arresta l'ascolto vocale
  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    } else {
      var status = await Permission.microphone.request();
      if (status.isGranted) {
        bool available = await _speech.initialize(
          onStatus: (status) {
            if (status == 'done' || status == 'notListening') {
              setState(() => _isListening = false);
            }
          },
          onError: (errorNotification) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Avviso: ${errorNotification.errorMsg}')),
              );
            }
          },
        );

        if (available) {
          setState(() => _isListening = true);
          _speech.listen(
            localeId: 'it_IT',
            listenMode: stt.ListenMode.dictation,
            onResult: (result) {
              setState(() {
                _transcribedText = result.recognizedWords;
                _textController.text = _transcribedText;
              });
            },
          );
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Riconoscimento vocale non disponibile sul dispositivo.')),
            );
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permesso microfono non concesso.')),
          );
        }
      }
    }
  }

  // Salvataggio in formato .TXT
  Future<void> _saveAsTxt() async {
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun testo da salvare.')),
      );
      return;
    }

    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${directory.path}/trascrizione_$timestamp.txt');

    await file.writeAsString(_textController.text);
    _showResultDialog(file.path, 'TXT');
  }

  // Salvataggio in formato .PDF
  Future<void> _saveAsPdf() async {
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun testo da salvare.')),
      );
      return;
    }

    final pdf = pw.Document();
    final dateStr = DateTime.now().toString().split('.')[0];

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) => pw.Padding(
          padding: const pw.EdgeInsets.all(24),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Nota Trascrizione Vocale',
                style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 6),
              pw.Text('Data: $dateStr', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
              pw.Divider(),
              pw.SizedBox(height: 12),
              pw.Text(
                _textController.text,
                style: const pw.TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );

    final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${directory.path}/trascrizione_$timestamp.pdf');

    await file.writeAsBytes(await pdf.save());
    _showResultDialog(file.path, 'PDF');
  }

  // Finestra di dialogo con tasto rapido per inviare a PC / Drive
  void _showResultDialog(String filePath, String type) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('File $type salvato!'),
        content: Text('File creato con successo:\n\n$filePath'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.share),
            label: const Text('Condividi / Invia a PC'),
            onPressed: () {
              Navigator.pop(ctx);
              Share.shareXFiles([XFile(filePath)], text: 'Trascrizione vocale');
            },
          ),
          FilledButton(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trascrizione Vocale'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: _isListening
                      ? '🎙️ Sto ascoltando... Parla vicino al microfono.'
                      : 'Premi il pulsante del microfono in basso per dettare o scrivi direttamente qui...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: _saveAsTxt,
                  icon: const Icon(Icons.description),
                  label: const Text('Salva .TXT'),
                ),
                ElevatedButton.icon(
                  onPressed: _saveAsPdf,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Salva .PDF'),
                ),
              ],
            ),
            const SizedBox(height: 70), // Spazio per il FloatingActionButton
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleListening,
        backgroundColor: _isListening ? Colors.red.shade700 : Theme.of(context).colorScheme.primary,
        icon: Icon(_isListening ? Icons.stop : Icons.mic, color: Colors.white),
        label: Text(
          _isListening ? 'Interrompi Registrazione' : 'Avvia Ascolto Vocale',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
