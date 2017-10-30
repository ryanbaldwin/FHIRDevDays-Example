//
//  PatientModel.swift
//  FHIRDevDays
//
//  Created by Ryan Baldwin on 2017-10-08.
//  Copyright © 2017 bunnyhug.me. All rights reserved.
//

import Foundation
import UIKit
import FireKit
import RealmSwift
import Restivus

/// A model used for showing and /or editing the details of a Patient.
class PatientModel {
    /// The gender of the Patient, as defined by FHIR DSTU2's `AdministrativeGender`
    ///
    /// - male: The patient's gender is male
    /// - female: The patient's gender is female
    /// - other: The patient's gender is other
    /// - unknown: The patient's gender is unknown
    enum Gender: Int {
        case male, female, other, unknown
    }
    
    /// An optional call back to notify a listener if the
    /// patient contained in this model is in a saveable state.
    /// When `true`, the patient can be saved; otherwise false.
    var patientCanSaveChanged: ((Bool) -> ())? = nil
    
    /// An optional call back to notify a listener if the patient
    /// managed by this model has been updated.
    var managedPatientUpdated:(() -> ())? = nil
    
    /// The Realm used by this instance
    private var realm = try! Realm()
    
    /// The patient to edit. If this instance is creating a new Patient, then `patient` will be nil.
    private var patientToEdit: Patient? {
        didSet {
            if let patient = patientToEdit {
                setup(withPatient: patient)
            } else {
                gender = nil
                givenName = nil
                familyName = nil
                dateOfBirth = nil
                telecoms = []
            }
        }
    }
    
    /// Returns true if this patient can be downloaded from the remote FHIR server; otherwise false.
    var canDownloadPatient: Bool {
        return patientToEdit?.id != nil
    }
    
    /// Returns `true` if the patient can be uploaded to the remote FHIR server; otherwise `false`
    var canUploadPatient: Bool {
        guard let patient = self.patientToEdit else { return false }
        return realm.object(ofType: Patient.self, forPrimaryKey: patient.pk) != nil
    }
    
    /// Returns the `Reference` for the patient under edit.
    /// If this instance is being used to create a new patient,
    /// or edit a patient which has not been uploaded to the remote FHIR server,
    /// then `reference` returns nil.
    var reference: Reference? {
        guard let patientId = patientToEdit?.id else { return nil }
        return Reference(withReferenceId: "\(Patient.resourceType)/\(patientId)")
    }
    
    /// The image for this instance's patient's avatar
    var image: UIImage?

    /// The given name for this instance's patient
    var givenName: String? {
        didSet {
            patientCanSaveChanged?(canSave)
        }
    }
    
    /// The family name for this instance's patient
    var familyName: String? {
        didSet {
            patientCanSaveChanged?(canSave)
        }
    }
    
    /// The date of birth of this instance's patient
    var dateOfBirth: Date? {
        didSet {
            patientCanSaveChanged?(canSave)
        }
    }
    
    /// The gender (defined by FHIR's `AdministrativeGender`) of this isntance's patient
    var gender: Gender? {
        didSet {
            patientCanSaveChanged?(canSave)
        }
    }
    
    /// An array of FHIR `ContactPoint`s for this isntance's patient. Defaults to empty.
    var telecoms: [ContactPoint] = []
    
    /// Returns `true` if the patient can be saved; otherwise `false`.
    var canSave: Bool {
        return self.givenName?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0 > 0
            && self.familyName?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0 > 0
            && self.dateOfBirth != nil
            && self.gender != nil
    }
    
    /// Initializes this instance of the PatientModel
    ///
    /// - Parameter patient: When provided, this instance will operate in "edit mode" for the givne patient;
    ///                      otherwise this instance will create a new patient.
    init(patient: Patient? = nil) {
        guard let patient = patient else { return }
        self.patientToEdit = patient
        setup(withPatient: patient)
    }
    
    /// Setup this instance to operate over the provided `Patient`
    ///
    /// - Parameter patient: The `Patient` to edit for this instance.
    private func setup(withPatient patient: Patient) {
        givenName = patient.name.first?.given.first?.value
        familyName = patient.name.first?.family.first?.value
        dateOfBirth = patient.birthDate?.nsDate
        telecoms = patient.telecom.flatMap { $0.copy() as? ContactPoint }
        
        if let patientGender = patient.gender {
            switch patientGender {
            case "male": gender = .male
            case "female": gender = .female
            case "other": gender = .other
            default: gender = .unknown
            }
        }
        
        if let base64String = patient.photo.first?.data?.value,
            let image = UIImage(base64EncodedString: base64String) {
            self.image = image
        }
    }
    
    /// Permanently persists this patien to the local Realm.
    func save() {
        guard canSave else {
            print("Sorry, but you can't save yet. There are required fields.")
            return
        }
        
        do {
            let  patient = patientToEdit == nil
                ? Patient()
                : realm.object(ofType: Patient.self, forPrimaryKey: patientToEdit!.pk) ?? Patient()
            
            try realm.write {
                if patient.name.first == nil {
                    patient.name.append(HumanName())
                }
                
                if patient.name.first!.given.first == nil {
                    patient.name.first!.given.append(RealmString())
                }
                patient.name.first!.given.first!.value = givenName!
                
                if patient.name.first!.family.first == nil {
                    patient.name.first!.family.append(RealmString())
                }
                patient.name.first!.family.first!.value = familyName!
                
                patient.gender = String(describing: self.gender!)
                patient.birthDate = dateOfBirth!.fhir_asDate()
                
                patient.telecom.cascadeDelete()
                patient.telecom.append(objectsIn: Array(telecoms.flatMap { $0.copy() as? ContactPoint }))
                
                if let userImage = image {
                    if let jpeg = UIImageJPEGRepresentation(userImage, 0.8) {
                        if patient.photo.first == nil {
                            patient.photo.append(Attachment())
                        }
                        patient.photo.first!.data = Base64Binary(string: jpeg.base64EncodedString(options: .lineLength64Characters))
                    }
                } else if let existingPhoto = patient.photo.first {
                    patient.photo.remove(objectAtIndex: 0)
                    realm.delete(existingPhoto)
                }
                
                // if this is a new patient, we must add it to the realm.
                if patientToEdit == nil { realm.add(patient) }
                patientToEdit = patient
            }
        } catch let error {
            print("Failed to commit transaction when creating/updating patient: \(error)")
        }
    }
    
    /// Uploads this patient to the server and
    ///
    /// - Parameter completion: called after a response is returned from the server, and an attempt was made
    ///                         Any errors that occured will be forwarded, or nil if everything worked as expected.
    ///
    /// Expected errors in the `completion` handler can be:
    ///   - [Restivus.HTTPError](https://ryanbaldwin.github.io/Restivus/docs/Enums/HTTPError.html):
    ///         Returned if the response received from the server is anything other than 2xx
    ///   - NSError: Returned if the attempt to save the patient locally fails.
    ///
    /// - Throws: `PatientOperationError` if:
    ///   - This instance is not managing a Patient
    ///   - The patient cannot be uploaded (possibly because it hasn't been saved yet)
    ///   - The attempt to submit the upload request failed
    func uploadPatient(completion: ((Error?) -> ())? = nil) throws {
        guard canUploadPatient, let patient = patientToEdit else {
            print("Cannot upload the patient at this time. Has the patient been saved?")
            throw PatientOperationError(message: "Cannot upload the patient at this time. Has the patient been saved?",
                                        error: nil)
        }
        
        let uploadRequest = makeUploadPatientRequest(for: patient)
        do {
            _ = try uploadRequest.submit() { [weak self] result in
                switch result {
                case let .success(uploadPatient):
                    try! self?.realm.write { self?.patientToEdit?.populate(from: uploadPatient)}
                    completion?(nil)
                case let .failure(error):
                    completion?(error)
                }
            }
        } catch let error {
            print("Failed to submit request: \(error)")
            throw PatientOperationError(message: "Failed to create UploadPatientRequest", error: error)
        }
    }
    
    /// Creates the appropriate Upload request type (POST vs PUT) for a given patient, using the patient's `id`
    /// as a guideline as to whether or not the patient already exists on the server.
    ///
    /// - Parameter patient: The patient to be uploaded to the server
    /// - Returns: an `AnyRestable<Patient>` which will upload the patient to the server.
    private func makeUploadPatientRequest(for patient: Patient) -> AnyRestable<Patient> {
        let patientToUpload = realm.object(ofType: Patient.self, forPrimaryKey: patient.pk)!
        
        if patientToUpload.id == nil {
            return AnyRestable<Patient>(PostPatientRequest(patientToUpload))
        }
        
        return AnyRestable<Patient>(UpdatePatientRequest(patientToUpload))
    }
    
    /// Downloads this patient from the server and
    ///
    /// - Parameter completion: called after a response is returned from the server, and an attempt was made
    ///                         Any errors that occured will be forwarded, or nil if everything worked as expected.
    ///
    /// Expected errors in the `completion` handler can be:
    ///   - [Restivus.HTTPError](https://ryanbaldwin.github.io/Restivus/docs/Enums/HTTPError.html):
    ///         Returned if the response received from the server is anything other than 2xx
    ///   - NSError: Returned if the attempt to save the patient locally fails.
    ///
    /// - Throws: `PatientOperationError` if:
    ///   - This instance is not managing a Patient
    ///   - The patient cannot be downloaded.
    ///   - The attempt to download the patient failed
    func downloadPatient(completion: ((Error?) -> ())? = nil) throws {
        guard canDownloadPatient, let patient = patientToEdit else {
            print("Cannot download the patient at this time. Does the patient have a proper `Reference`?")
            throw PatientOperationError(
                message: "Cannot download the patient at this time. Does the patient have a proper FHIR Reference?",
                error: nil)
        }
        
        do {
            _ = try DownloadPatientRequest(resourceId: patient.id!).submit() { [weak self] result in
                switch result {
                case let .success(downloadedPatient):
                    do {
                        try self?.realm.write { self?.patientToEdit = self?.realm.upsert(downloadedPatient) }
                        completion?(nil)
                    } catch let error {
                        completion?(error)
                    }
                    
                case let .failure(error):
                    completion?(error)
                }
            }
        } catch let error {
            print("Failed to submit request: \(error)")
            throw PatientOperationError(message: "failed to create DownloadPatientRequest", error: error)
        }
    }
}

/// An Error returned when an attempt to create a remote patient operation (such as upload or download a patient) fails.
struct PatientOperationError: Error {
    var message: String
    var error: Error?
}
