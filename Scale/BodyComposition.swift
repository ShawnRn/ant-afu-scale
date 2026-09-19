import Foundation

/// 身体健康指标评估等级
enum HealthRating: String, CaseIterable, Codable {
    case low = "偏低"
    case normal = "标准"
    case optimal = "优"
    case high = "偏高"
    case veryHigh = "严重偏高"

    /// 对应的标签背景色名称或分类，用于 UI 显示
    var statusType: StatusType {
        switch self {
        case .normal: return .normal
        case .optimal: return .optimal
        case .low: return .warning
        case .high: return .warning
        case .veryHigh: return .alert
        }
    }

    enum StatusType {
        case normal
        case optimal
        case warning
        case alert
    }
}

/// 一次测量的完整结果模型（对标阿福/沃莱官方 18+ 项身体指标）。
struct Measurement: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    let date: Date
    let weightKg: Double
    let impedance: Double              // 阻抗 Ω
    let bmi: Double                    // BMI
    let leanBodyMassKg: Double         // 去脂体重 kg

    // MARK: - 脂肪指标
    let bodyFatPercent: Double          // 体脂率 %
    let fatMassKg: Double               // 脂肪量 kg
    let subcutaneousFatPercent: Double  // 皮下脂肪率 %
    let subcutaneousFatMassKg: Double   // 皮下脂肪量 kg
    let visceralFat: Double             // 内脏脂肪等级

    // MARK: - 肌肉与骨骼指标
    let muscleRate: Double              // 肌肉率 %
    let muscleMassKg: Double            // 肌肉量 kg
    let skeletalMusclePercent: Double   // 骨骼肌率 %
    let skeletalMuscleMassKg: Double    // 骨骼肌量 kg
    let bonePercent: Double             // 骨量占比 %
    let boneMassKg: Double              // 骨量 kg

    // MARK: - 水分与营养指标
    let waterPercent: Double            // 体水分率 %
    let waterMassKg: Double             // 体水分量 kg
    let proteinPercent: Double          // 蛋白量占比 %
    let proteinMassKg: Double           // 蛋白量含量 kg
    let bmr: Int                        // 基础代谢 kcal

    init(id: UUID = UUID(),
         date: Date = Date(),
         weightKg: Double,
         impedance: Double,
         bmi: Double,
         leanBodyMassKg: Double,
         bodyFatPercent: Double,
         fatMassKg: Double,
         subcutaneousFatPercent: Double,
         subcutaneousFatMassKg: Double,
         visceralFat: Double,
         muscleRate: Double,
         muscleMassKg: Double,
         skeletalMusclePercent: Double,
         skeletalMuscleMassKg: Double,
         bonePercent: Double,
         boneMassKg: Double,
         waterPercent: Double,
         waterMassKg: Double,
         proteinPercent: Double,
         proteinMassKg: Double,
         bmr: Int) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.impedance = impedance
        self.bmi = bmi
        self.leanBodyMassKg = leanBodyMassKg
        self.bodyFatPercent = bodyFatPercent
        self.fatMassKg = fatMassKg
        self.subcutaneousFatPercent = subcutaneousFatPercent
        self.subcutaneousFatMassKg = subcutaneousFatMassKg
        self.visceralFat = visceralFat
        self.muscleRate = muscleRate
        self.muscleMassKg = muscleMassKg
        self.skeletalMusclePercent = skeletalMusclePercent
        self.skeletalMuscleMassKg = skeletalMuscleMassKg
        self.bonePercent = bonePercent
        self.boneMassKg = boneMassKg
        self.waterPercent = waterPercent
        self.waterMassKg = waterMassKg
        self.proteinPercent = proteinPercent
        self.proteinMassKg = proteinMassKg
        self.bmr = bmr
    }

    // MARK: - 各项指标评估状态计算
    var bmiRating: HealthRating {
        if bmi < 18.5 { return .low }
        if bmi < 24.0 { return .normal }
        if bmi < 28.0 { return .high }
        return .veryHigh
    }

    func bodyFatRating(isMale: Bool) -> HealthRating {
        if isMale {
            if bodyFatPercent < 10.0 { return .low }
            if bodyFatPercent <= 20.0 { return .normal }
            if bodyFatPercent <= 25.0 { return .high }
            return .veryHigh
        } else {
            if bodyFatPercent < 20.0 { return .low }
            if bodyFatPercent <= 30.0 { return .normal }
            if bodyFatPercent <= 35.0 { return .high }
            return .veryHigh
        }
    }

    var fatMassRating: HealthRating {
        // 与体脂率趋势保持一致
        return bodyFatRating(isMale: true)
    }

    func subcutaneousFatRating(isMale: Bool) -> HealthRating {
        if isMale {
            if subcutaneousFatPercent < 8.6 { return .low }
            if subcutaneousFatPercent <= 16.7 { return .normal }
            return .high
        } else {
            if subcutaneousFatPercent < 18.5 { return .low }
            if subcutaneousFatPercent <= 26.7 { return .normal }
            return .high
        }
    }

    var visceralFatRating: HealthRating {
        if visceralFat <= 9.0 { return .normal }
        if visceralFat <= 14.0 { return .high }
        return .veryHigh
    }

    func muscleRating(isMale: Bool) -> HealthRating {
        if isMale {
            if muscleRate < 65.0 { return .low }
            if muscleRate <= 85.0 { return .normal }
            return .optimal
        } else {
            if muscleRate < 55.0 { return .low }
            if muscleRate <= 75.0 { return .normal }
            return .optimal
        }
    }

    func skeletalMuscleRating(isMale: Bool) -> HealthRating {
        if isMale {
            if skeletalMusclePercent < 49.0 { return .low }
            if skeletalMusclePercent <= 59.0 { return .normal }
            return .optimal
        } else {
            if skeletalMusclePercent < 40.0 { return .low }
            if skeletalMusclePercent <= 50.0 { return .normal }
            return .optimal
        }
    }

    func boneRating(isMale: Bool) -> HealthRating {
        let threshold = isMale ? (weightKg < 60.0 ? 2.5 : (weightKg <= 75.0 ? 2.9 : 3.2))
                               : (weightKg < 45.0 ? 1.8 : (weightKg <= 60.0 ? 2.2 : 2.5))
        if boneMassKg < threshold { return .low }
        return .normal
    }

    func waterRating(isMale: Bool) -> HealthRating {
        if isMale {
            if waterPercent < 55.0 { return .low }
            if waterPercent <= 65.0 { return .normal }
            return .optimal
        } else {
            if waterPercent < 45.0 { return .low }
            if waterPercent <= 60.0 { return .normal }
            return .optimal
        }
    }

    var proteinRating: HealthRating {
        if proteinPercent < 16.0 { return .low }
        if proteinPercent <= 18.0 { return .normal }
        if proteinPercent <= 22.0 { return .optimal }
        return .high
    }

    func bmrRating(profile: UserProfile) -> HealthRating {
        // 参考 Harris-Benedict 基础标准值
        let standardBMR: Double
        if profile.isMale {
            standardBMR = 66.5 + (13.75 * weightKg) + (5.003 * profile.heightCm) - (6.775 * Double(profile.age))
        } else {
            standardBMR = 655.1 + (9.563 * weightKg) + (1.850 * profile.heightCm) - (4.676 * Double(profile.age))
        }
        return Double(bmr) >= standardBMR ? .normal : .low
    }
}

/// 体脂等身体成分的本地估算（BIA 公式）。
/// 对标蚂蚁阿福 / 沃莱（Welland）官方使用的生物电阻抗多阶分析模型。
enum BodyComposition {

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        return max(low, min(high, value))
    }

    static func calculate(weightKg rawWeight: Double,
                          impedance rawImpedance: Double,
                          profile: UserProfile) -> Measurement {
        let weight = (rawWeight * 100).rounded() / 100
        let h = profile.heightCm
        let age = Double(profile.age)
        let isMale = profile.isMale
        let impedance = rawImpedance > 0 ? rawImpedance : 500.0

        let heightM = h / 100.0
        let bmi = (weight / pow(heightM, 2) * 10).rounded() / 10.0
        let heightSq = h * h

        // MARK: 1. 瘦体重 (FFM / Lean Body Mass) 与 体脂率 (Body Fat Percentage)
        // 采用 Segal BIA 回归方程
        var ffm: Double
        if isMale {
            ffm = 9.33285 + (0.00066360 * heightSq) - (0.02117 * impedance) + (0.62854 * weight) - (0.12380 * age)
            let bfp = 100.0 * (weight - ffm) / weight
            if bfp >= 20.0 {
                ffm = 14.52435 + (0.00088580 * heightSq) - (0.02999 * impedance) + (0.42688 * weight) - (0.07002 * age)
            }
        } else {
            ffm = 10.43485 + (0.00064602 * heightSq) - (0.01397 * impedance) + (0.42087 * weight)
            let bfp = 100.0 * (weight - ffm) / weight
            if bfp >= 30.0 {
                ffm = 9.37938 + (0.00091186 * heightSq) - (0.01466 * impedance) + (0.29990 * weight) - (0.07012 * age)
            }
        }

        ffm = clamp(ffm, weight * 0.35, weight * 0.97)
        var fatPct = 100.0 * (weight - ffm) / weight
        fatPct = clamp(fatPct, isMale ? 3.0 : 8.0, 60.0)

        let fatMassKg = (weight * fatPct / 100.0 * 10).rounded() / 10.0
        let leanBodyMassKg = ((weight - fatMassKg) * 10).rounded() / 10.0

        // MARK: 2. 骨量 (Bone Mass)
        let bonePercent = isMale ? 4.5 : 4.0
        let boneMassKg = (weight * (bonePercent / 100.0) * 10).rounded() / 10.0

        // MARK: 3. 肌肉率与肌肉量 (Muscle)
        var musclePct = clamp(100.0 - fatPct - bonePercent, 20.0, 95.0)
        musclePct = (musclePct * 10).rounded() / 10.0
        let muscleMassKg = (weight * (musclePct / 100.0) * 10).rounded() / 10.0

        // MARK: 4. 骨骼肌 (Skeletal Muscle)
        // 骨骼肌占全身肌肉约 53%
        var skeletalPct = clamp(musclePct * 0.5306, 10.0, 70.0)
        skeletalPct = (skeletalPct * 10).rounded() / 10.0
        let skeletalMassKg = (weight * (skeletalPct / 100.0) * 10).rounded() / 10.0

        // MARK: 5. 水分率与水分量 (Water)
        let leanPct = 100.0 - fatPct
        var waterPct = clamp(leanPct * 0.70, 25.0, 80.0)
        waterPct = (waterPct * 10).rounded() / 10.0
        let waterMassKg = (weight * (waterPct / 100.0) * 10).rounded() / 10.0

        // MARK: 6. 蛋白质 (Protein)
        var proteinPct = clamp(leanPct * 0.238, 5.0, 35.0)
        proteinPct = (proteinPct * 10).rounded() / 10.0
        let proteinMassKg = (weight * (proteinPct / 100.0) * 10).rounded() / 10.0

        // MARK: 7. 皮下脂肪 (Subcutaneous Fat)
        var subFatPct = clamp(fatPct * 0.72, 1.0, fatPct)
        subFatPct = (subFatPct * 10).rounded() / 10.0
        let subFatMassKg = (weight * (subFatPct / 100.0) * 10).rounded() / 10.0

        // MARK: 8. 内脏脂肪等级 (Visceral Fat Grade)
        var vfal: Double
        if isMale {
            if h < weight * 1.6 {
                let subcalc = (h * (h * 0.0826)) - (h * 0.4)
                vfal = ((weight * 305.0) / (subcalc + 48.0)) - 2.9 + (age * 0.15)
            } else {
                let subcalc = 0.765 - (h * 0.0015)
                vfal = (((h * 0.143) - (weight * subcalc)) * -1.0) + (age * 0.15) - 5.0
            }
        } else {
            if weight > ((h * 0.5) - 13.0) {
                let subsubcalc = (h * 1.45) + (h * 0.1158 * h) - 120.0
                let subcalc = (weight * 500.0) / subsubcalc
                vfal = (subcalc - 6.0) + (age * 0.07)
            } else {
                let subcalc = 0.691 - (h * 0.0048)
                vfal = (((h * 0.027) - (subcalc * weight)) * -1.0) + (age * 0.07) - age
            }
        }
        let visceralFat = (clamp(vfal, 1.0, 50.0) * 10).rounded() / 10.0

        // MARK: 9. 基础代谢 (BMR, Katch-McArdle 公式结合去脂体重)
        let bmrValue = Int((370.0 + (21.6 * leanBodyMassKg)).rounded())

        return Measurement(
            date: Date(),
            weightKg: weight,
            impedance: (impedance * 10).rounded() / 10,
            bmi: bmi,
            leanBodyMassKg: leanBodyMassKg,
            bodyFatPercent: (fatPct * 10).rounded() / 10.0,
            fatMassKg: fatMassKg,
            subcutaneousFatPercent: subFatPct,
            subcutaneousFatMassKg: subFatMassKg,
            visceralFat: visceralFat,
            muscleRate: musclePct,
            muscleMassKg: muscleMassKg,
            skeletalMusclePercent: skeletalPct,
            skeletalMuscleMassKg: skeletalMassKg,
            bonePercent: bonePercent,
            boneMassKg: boneMassKg,
            waterPercent: waterPct,
            waterMassKg: waterMassKg,
            proteinPercent: proteinPct,
            proteinMassKg: proteinMassKg,
            bmr: bmrValue
        )
    }
}
