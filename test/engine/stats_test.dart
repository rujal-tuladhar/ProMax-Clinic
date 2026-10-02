import 'package:fitsize/engine/stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('median', () {
    test('odd length', () {
      expect(median([3, 1, 2]), 2);
    });

    test('even length averages the middle pair', () {
      expect(median([4, 1, 3, 2]), 2.5);
    });

    test('single element', () {
      expect(median([7]), 7);
    });

    test('does not mutate its input', () {
      final xs = [3.0, 1.0, 2.0];
      median(xs);
      expect(xs, [3.0, 1.0, 2.0]);
    });
  });

  group('mad', () {
    test('known value', () {
      // median = 2; |x-2| = [1,1,0,0,2,4,7]; median of those = 1.
      expect(mad([1, 1, 2, 2, 4, 6, 9]), 1);
    });

    test('constant list has zero MAD', () {
      expect(mad([5, 5, 5]), 0);
    });
  });

  group('rejectOutliers', () {
    test('removes a gross outlier', () {
      final kept = rejectOutliers([1.0, 1.1, 0.9, 1.05, 50.0]);
      expect(kept, isNot(contains(50.0)));
      expect(kept, containsAll([1.0, 1.1, 0.9, 1.05]));
    });

    test('keeps values exactly at k*MAD', () {
      // median 1.05, MAD 0.05 -> 0.9 deviates exactly 3*MAD and stays.
      final kept = rejectOutliers([1.0, 1.1, 0.9, 1.05, 50.0]);
      expect(kept, contains(0.9));
    });

    test('returns input unchanged when MAD is zero', () {
      final xs = [5.0, 5.0, 5.0, 100.0];
      expect(rejectOutliers(xs), xs);
    });

    test('respects a custom k', () {
      // median 10, MAD 1; 14 deviates 4*MAD.
      final xs = [9.0, 10.0, 11.0, 14.0, 10.0];
      expect(rejectOutliers(xs, k: 3), isNot(contains(14.0)));
      expect(rejectOutliers(xs, k: 5), contains(14.0));
    });

    test('short lists pass through', () {
      expect(rejectOutliers([42.0]), [42.0]);
      expect(rejectOutliers([]), isEmpty);
    });
  });

  group('stdDev', () {
    test('sample standard deviation of a known set', () {
      // mean 5, sum of squared deviations 32, n-1 = 7.
      expect(stdDev([2, 4, 4, 4, 5, 5, 7, 9]),
          closeTo(2.1380899352993947, 1e-12));
    });

    test('zero for fewer than two samples', () {
      expect(stdDev([]), 0);
      expect(stdDev([3.3]), 0);
    });

    test('zero for a constant list', () {
      expect(stdDev([2, 2, 2]), 0);
    });
  });
}
