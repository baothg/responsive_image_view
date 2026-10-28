import 'package:flutter/material.dart';
import 'package:responsive_image_view/responsive_image_view.dart';

void main() => runApp(const MaterialApp(home: Demo()));

const urls = [
  'https://images.pexels.com/photos/534164/pexels-photo-534164.jpeg',
  'https://images.pexels.com/photos/17180777/pexels-photo-17180777.jpeg',
  'https://images.pexels.com/photos/19387200/pexels-photo-19387200.jpeg',
  'https://images.pexels.com/photos/38149817/pexels-photo-38149817.jpeg',
  'https://images.pexels.com/photos/28618883/pexels-photo-28618883.jpeg',
  'https://images.pexels.com/photos/27222019/pexels-photo-27222019.jpeg',
  'https://images.pexels.com/photos/28618884/pexels-photo-28618884.jpeg',
  'https://images.pexels.com/photos/20762934/pexels-photo-20762934.jpeg',
  'https://images.pexels.com/photos/13744218/pexels-photo-13744218.jpeg',
  'https://images.pexels.com/photos/27421515/pexels-photo-27421515.jpeg',
  'https://images.pexels.com/photos/37617308/pexels-photo-37617308.jpeg',
];

class Demo extends StatelessWidget {
  const Demo({super.key});

  static Widget img(String url, {double? w, double? h}) => ResponsiveImageView(
    url,
    width: w,
    height: h,
    fit: BoxFit.cover,
    placeholder: (_) => const ColoredBox(color: Colors.black12),
    errorBuilder: (_, e, retry) =>
        IconButton(icon: const Icon(Icons.refresh), onPressed: retry),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ResponsiveImageView')),
      body: ListView(
        children: [
          img(urls[0], h: 420), // L
          Row(
            children: [
              Expanded(child: img(urls[1], h: 200)), // M
              Expanded(child: img(urls[2], h: 200)), // M
            ],
          ),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 4,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            children: [
              for (var i = 3; i < urls.length; i++) img(urls[i], w: 90, h: 90),
            ], // S
          ),
          const Divider(),
          for (var i = 0; i < urls.length; i++) // list: M per row
            ListTile(
              leading: SizedBox(
                width: 72,
                height: 72,
                child: img(urls[i], w: 72, h: 72),
              ),
              title: Text('Photo ${i + 1}'),
              subtitle: Text(
                urls[i].split('/').last,
                style: const TextStyle(fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }
}
