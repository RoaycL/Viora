import '../../domain/models/external_rating.dart';
import '../../domain/models/ratings_settings.dart';

abstract interface class RatingProvider {
  RatingProviderId get id;
  bool supports(RatingQuery query);
  Future<RatingsData> fetch(RatingQuery query);
}
