﻿// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.IO;
using System.Threading.Tasks;

namespace Microsoft.Quantum.Qir.Tools
{
    /// <summary>
    /// Provides high-level utility methods to work with QIR.
    /// </summary>
    public static class QirTools
    {

        /// <summary>
        /// Creates a QIR-based executable from a .NET DLL generated by the Q# compiler.
        /// </summary>
        /// <param name="qsharpDll">.NET DLL generated by the Q# compiler.</param>
        /// <param name="libraryDirectory">Directory where the libraries to link to are located.</param>
        /// <param name="includeDirectory">Directory where the headers needed for compilation are located.</param>
        public static Task BuildFromQSharpDll(FileInfo qsharpDll, DirectoryInfo libraryDirectory, DirectoryInfo includeDirectory, IQirExecutable? qirExecutable = null)
        {
            throw new NotImplementedException();
        }
    }
}
