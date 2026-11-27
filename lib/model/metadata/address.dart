import 'package:purer/geo/states.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

@immutable
class AddressDetails extends Equatable {
  final int id;
  final String? countryCode, countryName, adminArea, locality;

  @override
  List<Object?> get props => [id, countryCode, countryName, adminArea, locality];

  String? get place => locality != null && locality!.isNotEmpty ? locality : adminArea;

  String? get stateCode => GeoStates.stateCodeByName[stateName];

  String? get stateName => GeoStates.stateCodesByCountryCode.containsKey(countryCode) ? adminArea : null;

  const new({
    required this.id,
    this.countryCode,
    this.countryName,
    this.adminArea,
    this.locality,
  });

  AddressDetails copyWith({
    int? id,
  }) {
    return AddressDetails(
      id: id ?? this.id,
      countryCode: countryCode,
      countryName: countryName,
      adminArea: adminArea,
      locality: locality,
    );
  }

  factory fromMap(Map map) {
    return AddressDetails(
      id: map['id'] as int,
      countryCode: map['countryCode'] as String?,
      countryName: map['countryName'] as String?,
      adminArea: map['adminArea'] as String?,
      locality: map['locality'] as String?,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'countryCode': countryCode,
    'countryName': countryName,
    'adminArea': adminArea,
    'locality': locality,
  };

  Map<String, Object?> toDbMap() => toMap();

  bool get isValid {
    if (countryName?.isNotEmpty == true && countryCode == null) return false;
    return true;
  }
}

// address returned by the platform geocoder (kept for remote entry metadata)
@immutable
class Address extends Equatable {
  final String? addressLine, adminArea, countryCode, countryName, featureName, locality, postalCode, subAdminArea, subLocality, subThoroughfare, thoroughfare;

  @override
  List<Object?> get props => [addressLine, adminArea, countryCode, countryName, featureName, locality, postalCode, subAdminArea, subLocality, subThoroughfare, thoroughfare];

  const new({
    this.addressLine,
    this.adminArea,
    this.countryCode,
    this.countryName,
    this.featureName,
    this.locality,
    this.postalCode,
    this.subAdminArea,
    this.subLocality,
    this.subThoroughfare,
    this.thoroughfare,
  });

  factory fromMap(Map map) => Address(
    addressLine: map['addressLine'],
    adminArea: map['adminArea'],
    countryCode: map['countryCode'],
    countryName: map['countryName'],
    featureName: map['featureName'],
    locality: map['locality'],
    postalCode: map['postalCode'],
    subAdminArea: map['subAdminArea'],
    subLocality: map['subLocality'],
    subThoroughfare: map['subThoroughfare'],
    thoroughfare: map['thoroughfare'],
  );
}
