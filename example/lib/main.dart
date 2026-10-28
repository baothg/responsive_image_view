import 'package:flutter/material.dart';
import 'package:responsive_image_view/responsive_image_view.dart';

void main() => runApp(const MaterialApp(home: Demo()));

String _url(int i, int w, int h) => 'https://picsum.photos/seed/$i/$w/$h';

class Demo extends StatelessWidget {
  const Demo({super.key});

  @override
  Widget build(BuildContext context) {
    Widget img(int i, double w, double h, int sw, int sh) => ResponsiveImageView(
          _url(i, sw, sh),
          width: w,
          height: h,
          fit: BoxFit.cover,
          placeholder: (_) => const ColoredBox(color: Colors.black12),
          errorBuilder: (_, e) => const Icon(Icons.broken_image),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('ResponsiveImageView')),
      body: ListView(
        children: [
          img(1, double.infinity, 360, 4000, 3000),
          const Padding(padding: EdgeInsets.all(8), child: Text('L / M / S')),
          Wrap(spacing: 4, runSpacing: 4, children: [
            img(2, 200, 200, 3000, 3000),
            for (var i = 10; i < 40; i++) img(i, 80, 80, 3000, 3000),
          ]),
        ],
      ),
    );
  }
}
