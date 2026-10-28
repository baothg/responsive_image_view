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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ResponsiveImageView — 100 rows')),
      body: ListView.builder(
        itemCount: 100,
        itemBuilder: (context, index) {
          final count = index % 3 + 2; // 2, 3 or 4 images per row
          return Padding(
            padding: const EdgeInsets.all(2),
            child: Row(
              children: [
                for (var j = 0; j < count; j++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: AspectRatio(
                        aspectRatio: 3 / 2, // height = width * 2/3
                        child: ResponsiveImageView(
                          urls[(index + j) % urls.length],
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, retry) => IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: retry,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
