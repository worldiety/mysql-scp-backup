//
//  main.swift
//
//
//  Created by Julian Kahnert on 07.12.20.
//

import Foundation
@_exported import ShellOut

let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
let dateString = formatter.string(from: Date())
let dateSeparator = "--"


do {
    // validate environment variables
    let env = try Environment.getAndValidate()

    let tempLocationUrl = URL(fileURLWithPath: env.tempLocation, isDirectory: true)
    print("Using temp location: \(tempLocationUrl.path)")
    let dbNames = env.dbNamesJoined.split(separator: ",")
    print("Found database names: \(dbNames)")
    
    print("Saving private/public key.")
    try shellOut(to: "echo \"\(env.sshBase64PrivateKey)\" | base64 -d > /root/.ssh/id_rsa")
    try shellOut(to: "echo \"\(env.sshBase64PublicKey)\" | base64 -d > /root/.ssh/id_rsa.pub")
    try shellOut(to: "chmod -R 700 /root/.ssh/")
    try shellOut(to: "chmod 600 /root/.ssh/id_rsa")
    try shellOut(to: "chmod 644 /root/.ssh/id_rsa.pub")

    for databaseName in dbNames {
        print("Creating backup of: \(databaseName)")
        let outputFilename = "\(dateString)\(dateSeparator)\(env.serviceName)-\(databaseName)-backup.sql"
        let outputUrl = tempLocationUrl.appendingPathComponent(outputFilename)
        print("saving backup to: \(outputUrl.path)")

        // create mysql backup
        try shellOut(to: "mysqldump --host=\(env.dbHost) --user=\(env.dbUser) --password=\(env.dbPassword) --port=\(env.dbPort) \(databaseName) > \(outputUrl.path)")
        
        // save backup in external storage
        try shellOut(to: "scp -o StrictHostKeyChecking=no \(outputUrl.path) \(env.sshStorageUrl):/\(outputFilename)")
    }

    // return early, if all backups should be kept, e.g. value == 0
    guard env.backupsToKeep > 0 else { exit(0) }

    let filenames = (try shellOut(to: "echo 'ls -1 *-backup.sql' | sftp -q \(env.sshStorageUrl) | grep -v '^sftp>'"))
        .split(separator: "\n")

    let uniqueFilenameDates = Set(filenames.compactMap { $0.components(separatedBy: dateSeparator).first }).sorted()
    
    let fileNamesToDelete = uniqueFilenameDates
        .dropLast(env.backupsToKeep)
        .flatMap { filenameDate -> [String.SubSequence] in
            // filenameDate, e.g. "2020-12-07_10-59-40"
            let filenamePrefix = "\(filenameDate)\(dateSeparator)\(env.serviceName)-"
            
            // get all filename with that prefix
            return filenames.filter { $0.hasPrefix(filenamePrefix) }
        }
        // sftp does not like "rm file1 file2" - we have to create multiple rm statements ("rm file1\nrm file2") in a batchfile
        .map { "rm \($0)\n" }

    let cmd = "echo '\n\(fileNamesToDelete.joined())' | sftp -b - -q \(env.sshStorageUrl)"
    print("Running sftp batch delete:\n$ \(cmd)")
    try shellOut(to: cmd)
    
} catch {
    print("ERROR: \(error)")
    exit(1)
}
