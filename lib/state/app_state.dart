import 'package:flutter/material.dart';

class AppState extends ChangeNotifier {
  bool damageSelected = false;
  bool carcheckSelected = false;
  bool photoSelected = false;
  bool equipmentSelected = false;
  bool avilooSelected = false;// ✅ NEW

  void setTasks({
    required bool damage,
    required bool carcheck,
    required bool photo,
    required bool equipment,
    required bool aviloo, // ✅ NEW
  }) {
    damageSelected = damage;
    carcheckSelected = carcheck;
    photoSelected = photo;
    equipmentSelected = equipment;
    avilooSelected = aviloo;// ✅ NEW
    notifyListeners();
  }

  List<String> getSelectedTasks() {
    final tasks = <String>[];
    if (damageSelected) tasks.add('Relevé de dommages');
    if (carcheckSelected) tasks.add('Carcheck');
    if (photoSelected) tasks.add('Photo commercial');
    if (equipmentSelected) tasks.add('Relevé d’options');
    if (avilooSelected) tasks.add('Aviloo');// ✅ NEW
    return tasks;
  }
}
