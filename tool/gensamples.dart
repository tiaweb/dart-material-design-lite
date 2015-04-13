#!/usr/bin/env dart

import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:args/args.dart';

import 'package:logging/logging.dart';
import 'package:logging_handlers/logging_handlers_shared.dart';

import 'package:validate/validate.dart';

class Application {
    final Logger _logger = new Logger("gensamples.Application");

    static const _ARG_HELP              = 'help';
    static const _ARG_LOGLEVEL          = 'loglevel';
    static const _ARG_SETTINGS          = 'settings';
    static const _ARG_GENERATE          = 'gen';
    static const _ARG_GEN_STYLEGUIDE    = 'genstyleguide';
    static const _ARG_GENINDEX          = 'genindex';
    static const _ARG_MK_BACKUP         = 'makebackup';
    static const _ARG_SHOW_DIRS         = 'showdirs';
    static const _ARG_MV_MDL            = 'mvmdl';


    ArgParser _parser;

    Application() : _parser = Application._createOptions();

    void run(List<String> args) {

        try {
            final ArgResults argResults = _parser.parse(args);
            final Config config = new Config(argResults);

            _configLogging(config.loglevel);

            if (argResults[_ARG_HELP] || (config.dirstoscan.length == 0 && args.length == 0)) {
                _showUsage();
            }
            else if(argResults[_ARG_SETTINGS]) {
                _printSettings(config.settings);
            }
            else if(argResults[_ARG_SHOW_DIRS]) {
                _iterateThroughDirSync(config.sassdir,config.folderstoexclude.split("[,;]"),(final Directory dir) {
                    _logger.info(dir.path);
                });
            }
            else if(argResults[_ARG_GEN_STYLEGUIDE]) {
                _iterateThroughDirSync(config.sassdir,config.folderstoexclude.split("[,;]"),(final Directory dir) {
                    final String sampleName = dir.path.replaceFirst("${config.sassdir}/","");
                    _copyDemoCss(sampleName, dir,config.samplesdir);
                    _copySampleView(sampleName, dir,config.samplesdir);
                });
            }
            else if(argResults[_ARG_MV_MDL]) {
                _iterateThroughDirSync(config.sassdir,config.folderstoexclude.split("[,;]"),(final Directory dir) {
                    final String sampleName = dir.path.replaceFirst("${config.sassdir}/","");
                    _copyOrigFiles(sampleName, dir,config);
                });
                _copyOrigExtraFiles(config);
                _genMaterialDesignLiteCSS(config.sassdir);

            }
            else if(argResults[_ARG_GENERATE]) {
                final List<String> foldersToExclude = config.folderstoexclude.split("[,;]");

                _iterateThroughDirSync(config.sassdir,foldersToExclude,(final Directory dir) {
                    final String sampleName = dir.path.replaceFirst("${config.sassdir}/","");
                    _genSamples(sampleName,config);
                });
                _genMaterialDesignLiteCSS(config.sassdir);


            }  else if(argResults[_ARG_GENINDEX]) {
                final List<_LinkInfo> links = new List<_LinkInfo>();
                final List<String> foldersToExclude = config.folderstoexclude.split("[,;]");

                _iterateThroughExamplesDirSync(config.samplesdir,foldersToExclude,(final Directory dir) {
                    final String sampleName = dir.path.replaceFirst("${config.samplesdir}/","");

                    final Directory webDir = new Directory("${config.samplesdir}/${sampleName}/web");
                    final File targetDemo = new File("${webDir.path}/index.html");
                    final File srcJs = new File("${config.sassdir}/${sampleName}/${sampleName}.js");

                    links.add(new _LinkInfo(sampleName,targetDemo.path,srcJs.existsSync()));

                },recursive: false);
                _writeIndexHtml(config,links);
            }

            else {
                _showUsage();
            }
        }

        on FormatException
        catch (error) {
            _showUsage();
        }
    }


    // -- private -------------------------------------------------------------

    void _copyOrigFiles(final String sampleName,final Directory sassDir,final Config config) {
        Validate.notBlank(sampleName);
        Validate.notNull(sassDir);
        Validate.notNull(config);

        final String samplesDir = config.samplesdir;
        final String mdlDir = config.mdldir;

        final Directory mdlSampleDir = new Directory("${mdlDir}/$sampleName");

        if(!mdlSampleDir.existsSync()) {
            return;
        }

        void _copy(final String sampleName,final String extension,bool useOrigPostfix) {
            final File src = new File("${mdlSampleDir.path}/${sampleName}.$extension");

            if(!src.existsSync()) {
                _logger.fine("$sampleName: ${src.path} does not exists!");
                return;
            }

            final File target = new File("${sassDir.path}/${sampleName}${useOrigPostfix ? ".orig" : ""}.$extension");

            _logger.fine("$sampleName: ${src.path} -> ${target.path}");
            src.copySync(target.path);
        }

        _copy("_${sampleName}","scss",true);
        _copy("demo","html",false);
        _copy("demo","scss",sampleName == "typography"); // nur bei typography wird ein demo.orig.scss erstellt
        _copy("README","md",false);

        final File srcJS = new File("${mdlSampleDir.path}/${sampleName}.js");
        final File targetJS = new File("${config.jsbase}/${sampleName}.js");
        final File targetConvertedJS = new File("${config.portbase}/${sampleName}.js.dart");

        if(srcJS.existsSync()) {
            srcJS.copySync(targetJS.path);
            srcJS.copySync(targetConvertedJS.path);

            _Js2Dart(targetConvertedJS);
        }
    }

    void _copyOrigExtraFiles(final Config config) {
        Validate.notNull(config);

        final String sassDir = config.sassdir;
        final String mdlDir = config.mdldir;

        final Directory mdlSampleDir = new Directory("${mdlDir}");

        final File srcScss = new File("${mdlSampleDir.path}/_mixins.scss");
        final File targetScss = new File("${sassDir}/mixins/_mixins.orig.scss");

        _logger.fine("mixins: ${srcScss.path} -> ${targetScss.path}");

        srcScss.copySync(targetScss.path);

        final File srcJS = new File("${mdlDir}/mdlComponentHandler.js");
        final File targetConvertedJS = new File("${config.portbase}/mdlComponentHandler.js.dart");

        srcJS.copySync(targetConvertedJS.path);
        _Js2Dart(targetConvertedJS);
    }

    /// {sassDir} -> lib/sass/accordion
    void _copyDemoCss(final String sampleName,final Directory sassDir,final String samplesDir) {
        Validate.notBlank(sampleName);
        Validate.notNull(sassDir);
        Validate.notBlank(samplesDir);

        final File srcScss = new File("${sassDir.path}/demo.scss");
        final Directory targetScssDir = new Directory("${samplesDir}/styleguide/web/assets/styles/_demo");
        final File targetScss = new File("${targetScssDir.path}/_${sampleName}.scss");

        if(!srcScss.existsSync()) {
            return;
        }

        if(!targetScssDir.existsSync()) {
            targetScssDir.createSync(recursive: true);
        }

        _logger.info("$sampleName: ${srcScss.path} -> ${targetScss.path}");

        String content = srcScss.readAsStringSync();
        content = content.replaceAll(new RegExp(r"@import[^;]*;(\n|\r)*",caseSensitive: false, multiLine: true),"");

        targetScss.writeAsStringSync(content);
    }

    void _copySampleView(final String sampleName,final Directory sassDir,final String samplesDir) {
        Validate.notBlank(sampleName);
        Validate.notNull(sassDir);
        Validate.notBlank(samplesDir);

        final File secSampleOrig = new File("${sassDir.path}/demo.html");
        final File srcSampleDart = new File("${sassDir.path}/demo.dart.html");
        final File srcSample = srcSampleDart.existsSync() ? srcSampleDart : secSampleOrig;

        final Directory targetSampleDir = new Directory("${samplesDir}/styleguide/web/views");
        final File targetSample = new File("${targetSampleDir.path}/${sampleName}.html");

        if(!srcSample.existsSync()) {
            return;
        }

        if(!targetSampleDir.existsSync()) {
            targetSampleDir.createSync(recursive: true);
        }

        _logger.info("$sampleName: ${srcSample.path} -> ${targetSample.path}");

        String content = srcSample.readAsStringSync();

        content = content.replaceFirstMapped(
            new RegExp(
                r"(?:.|\n|\r)*" +
                r"<body[^>]*>([^<]*(?:(?!<\/?body)<[^<]*)*)<\/body[^>]*>" +
                r"(?:.|\n|\r)*",
                multiLine: true, caseSensitive: false),
                (final Match m) {

                return '${m[1]}';
            });

        content = content.replaceAll(new RegExp(r"<script[^>]*>.*</script>(?:\n|\r)*",caseSensitive: false, multiLine: true),"");
        content = content.replaceAll(new RegExp(r"^<!--[^>]*>.*(?:\n|\r)*",caseSensitive: false, multiLine: true),"");

        content = content.replaceAll(new RegExp(r"^",caseSensitive: false, multiLine: true),"    ");
        content = '<section class="demo-section demo-section--$sampleName">$content\n</section>';

        targetSample.writeAsStringSync(content);
        _reformatHtmlDemo(targetSample);
    }

    void _copySubdirs(final File sourceDir, final File targetDir, { int level: 0 } ) {
        Validate.notNull(sourceDir);
        Validate.notNull(targetDir);

        _logger.fine("Start!!!! ${sourceDir.path} -> ${targetDir.path} , Level: $level");
        final Directory directory = new Directory(sourceDir.path);
        directory.listSync(recursive: false).where((final FileSystemEntity entity) {
            // _logger.info("Check ${entity.path}");

            if(entity.path.startsWith(".") || entity.path.contains("/.")) {
                return false;
            }
            if(FileSystemEntity.isLinkSync(entity.path)) {
                return false;
            }

            if(entity.path.endsWith(".js") || entity.path.endsWith("/demo.html") || entity.path.endsWith("/demo.scss")) {
                return false;
            }

            return true;

        }).forEach((final FileSystemEntity entity) {
            //_logger.info("D ${entity.path}");

            if (FileSystemEntity.isDirectorySync(entity.path)) {
                //final File src = new File(entity.path);
                final File target = new File(entity.path.replaceFirst(sourceDir.path,""));
                _copySubdirs(new File("${entity.path}"),new File("${targetDir.path}${target.path}"),level: ++level);

            } else {
                if(level > 0) {
                    final File src = new File(entity.path);
                    final File target = new File("${targetDir.path}${entity.path.replaceFirst(sourceDir.path,"")}");
                    if(!target.existsSync()) {
                        target.createSync(recursive: true);
                    }
                    _logger.info("    copy ${src.path} -> ${target.path} (Level $level)...");
                    src.copySync(target.path);
                }
            }
        });
    }

    void _genSamples(final String sampleName,final Config config) {
        Validate.notBlank(sampleName);
        Validate.notNull(config);

        final Directory sampleDir = new Directory("${config.samplesdir}/${sampleName}");
        final Directory webDir = new Directory("${config.samplesdir}/${sampleName}/web");
        final Directory backupDir = new Directory("${config.samplesdir}/${sampleName}.backup");
        final Directory portBaseDir = new Directory(config.portbase);

        final File ignore = new File("${config.sassdir}/${sampleName}/.ignore");
        final File srcHtmlDemoOrig = new File("${config.sassdir}/${sampleName}/demo.html");
        final File srcHtmlDemoDart = new File("${config.sassdir}/${sampleName}/demo.dart.html");
        final File srcHtmlDemo = srcHtmlDemoDart.existsSync() ? srcHtmlDemoDart : srcHtmlDemoOrig;
        final File srcScss = new File("${config.sassdir}/${sampleName}/demo.scss");
        final File srcREADME = new File("${config.sassdir}/${sampleName}/README.md");
        final File targetDemo = new File("${webDir.path}/index.html");
        final File targetScss = new File("${webDir.path}/demo.scss");
        final File targetCss = new File("${webDir.path}/demo.css");
        final File targetREADME = new File("${webDir.path}/README.md");

        final File srcDartMain = new File("${config.sassdir}/${sampleName}/main.dart");
        final File srcTemplateDartMain = new File("${config.maintemplate}");
        final File targetDartMain = new File("${webDir.path}/main.dart");

        final Link targetPackages = new Link("${webDir.path}/packages");
        final File srcPackages = new File("../../../packages");

        // dir wird kpl. ignoriert
        if(ignore.existsSync()) {
            return;
        }

        // wenn es keine demo.html gibt dann ist das eine eigene Erweiterung!
        // sample ist in example schon angelegt
        if(!srcHtmlDemo.existsSync()) {
            return;
        }

        final Directory samplesDir = new Directory(config.samplesdir);
        if(!samplesDir.existsSync()) {
            samplesDir.createSync();
        }

        if(sampleDir.existsSync() && backupDir.existsSync()) {
            backupDir.deleteSync(recursive: true);
            _logger.fine("${backupDir.path} removed...");
        }
        if(sampleDir.existsSync() && config.mkbackup ) {
            sampleDir.renameSync(backupDir.path);
            _logger.fine("made ${sampleDir.path}} -> ${backupDir.path} backup...");

        } else if(sampleDir.existsSync()) {
            sampleDir.deleteSync(recursive: true);
            _logger.fine("${sampleDir.path} deleted...");
        }

        sampleDir.createSync();
        _logger.info("${sampleDir.path} created...");

        webDir.createSync();
        _logger.info("${webDir.path} created...");

        if(!portBaseDir.existsSync()) {
            portBaseDir.createSync(recursive: true);
        }

        if(srcHtmlDemo.existsSync()) {
            srcHtmlDemo.copySync(targetDemo.path);
            if(sampleName != "typography") {
                _reformatHtmlDemo(targetDemo);
            }

            if(srcDartMain.existsSync()) {
                _logger.fine("    ${srcDartMain.path} -> ${targetDartMain.path} copied...");
                srcDartMain.copySync(targetDartMain.path);
            }
            else {
                // wird angelegt auch wenn im SRC kein JS da ist - main.dart gibt es immer
                _logger.fine("    ${srcTemplateDartMain.path} -> ${targetDartMain.path} copied...");
                srcTemplateDartMain.copySync(targetDartMain.path);
            }
            _addDartMainToIndexHTML(targetDemo);

            if(!targetPackages.existsSync()) {
                targetPackages.createSync(srcPackages.path);
                _logger.fine("    ${srcPackages.path} created...");
            }

            _logger.fine("    ${targetDemo.path} created...");
        }

        if(srcScss.existsSync()) {
            srcScss.copySync(targetScss.path);
            _logger.fine("    ${targetScss.path} created...");
            _changeImportStatementInSassFile(targetScss,sampleName);
            _sasscAndAutoPrefix(targetScss,targetCss);
        }

        if(srcREADME.existsSync()) {
            _logger.fine("    ${srcREADME.path} -> ${targetREADME.path} copied...");
            srcREADME.copySync(targetREADME.path);
        }

        _copySubdirs(new File("${config.sassdir}/${sampleName}"),new File(webDir.path));
        _writeYaml(sampleName,config);
    }

    void _sasscAndAutoPrefix(final File targetScss,final File targetCss) {
        Validate.notNull(targetScss);
        Validate.notNull(targetCss);

        final ProcessResult result = Process.runSync('sassc', [targetScss.path, targetCss.path]);
        if(result.exitCode != 0) {
            _logger.severe(result.stderr);
        } else {
            _logger.fine("    ${targetCss.path} created...");
        }

        final ProcessResult resultPrefixer = Process.runSync('autoprefixer', [ targetCss.path]);
        if(resultPrefixer.exitCode != 0) {
            _logger.severe(resultPrefixer.stderr);
        } else {
            _logger.fine("    ${targetCss.path} prefixed...");
        }
    }

    void _reformatHtmlDemo(final File htmlDemo) {
        Validate.notNull(htmlDemo);

        String content = htmlDemo.readAsStringSync();

        content = content.replaceAll("<h2>","<h5>");
        content = content.replaceAll("</h2>","</h5>");
        content = content.replaceAll("<h3>","<h5>");
        content = content.replaceAll("</h3>","</h5>");

        htmlDemo.writeAsStringSync(content);
    }


    void _genMaterialDesignLiteCSS(final String samplesDir) {
        Validate.notBlank(samplesDir);

        final File srcScss = new File("${samplesDir}/material-design-lite.scss");
        final File targetCss = new File("${samplesDir}/material-design-lite.css");

        _logger.info("${srcScss.path} -> ${targetCss.path}");
        _sasscAndAutoPrefix(srcScss,targetCss);
    }

    void _Js2Dart(final File jsToConvert) {
        Validate.notNull(jsToConvert);
        Validate.notNull(jsToConvert.existsSync());

        final List<String> lines = jsToConvert.readAsLinesSync();
        final StringBuffer contents = new StringBuffer();
        bool isCommentTurnedOn = false;

        contents.writeln("import 'dart:html' as html;");
        contents.writeln("import 'dart:math' as Math;");
        contents.writeln();

        for(final String line in lines) {
            if(isCommentTurnedOn) {
                contents.writeln("// $line");
                continue;
            }
            if(line.contains("// in the global")) {
                isCommentTurnedOn = true;
                contents.writeln("// $line\n");
                continue;
            }

            if(line.contains("this.element_ = element;")) { continue; }
            if(line.contains("'use strict';")) { continue; }
            if(line.contains("* @private")) { continue; }
            if(line.contains("/**")) { continue; }
            if(line.contains(" */")) { continue; }

            String newLine = line.replaceAll("this.element_","element");
            newLine = newLine.replaceAll("this.CssClasses_.","_cssClasses.");
            newLine = newLine.replaceAll(".CssClasses_.","._cssClasses.");
            newLine = newLine.replaceAll(".classList.",".classes.");
            newLine = newLine.replaceAll(".appendChild(",".append(");
            newLine = newLine.replaceAll("this.Constant_.","_constant.");
            newLine = newLine.replaceAll("this.init()","init()");
            newLine = newLine.replaceAll("};","}");
            newLine = newLine.replaceAll("===","==");
            newLine = newLine.replaceAll("!==","!=");
            newLine = newLine.replaceAll(".bind(this)","");
            newLine = newLine.replaceAll("var ","final ");
            newLine = newLine.replaceAll("document.querySelector(","html.querySelector(");
            newLine = newLine.replaceAll("document.createElement('span')","new html.SpanElement()");
            newLine = newLine.replaceAll("document.createElement('div')","new html.DivElement()");
            newLine = newLine.replaceAll("document.getElementById","html.document.getElementById");
            newLine = newLine.replaceAll("if (element) {","if (element != null) {");
            newLine = newLine.replaceAll(".parentElement.",".parent.");

            if(newLine.contains("final ")) { contents.writeln(); }
            if(newLine.contains("= new html.")) { contents.writeln(); }
            if(newLine.contains("} else {")) { contents.writeln(); }

            newLine = newLine.replaceAllMapped(new RegExp('\s*([A-Z_]+):[ ]([0-9\-]+).*'),
                (final Match m) => "  final int ${m[1]} = ${m[2]};");

            newLine = newLine.replaceAllMapped(new RegExp("\s*([A-Z_]+):[ ]'([^']+)'.*"),
                (final Match m) => "  final String ${m[1]} = '${m[2]}';");

            newLine = newLine.replaceAllMapped(new RegExp("([^.]+).prototype.CssClasses_ ="),
                (final Match m) => "class _${m[1]}CssClasses");

            newLine = newLine.replaceAllMapped(new RegExp("([^.]+).prototype.Constant_ ="),
                (final Match m) => "class _${m[1]}Constant");

            newLine = newLine.replaceAllMapped(new RegExp("([^.]+).prototype.Mode_ ="),
                (final Match m) => "class _${m[1]}Mode");

            newLine = newLine.replaceAllMapped(new RegExp("([^.]+).prototype.([^_]+)(_*) = function\\(\\)"),
                (final Match m) => "/// $line\nvoid ${m[3]}${m[2]}()");

            newLine = newLine.replaceAllMapped(new RegExp("([^.]+).prototype.([^_]+)(_*) = function\\(([^\\)]+)\\)"),
                (final Match m) => "/// $line\nvoid ${m[3]}${m[2]}(final ${m[4]})");

            newLine = newLine.replaceAll("(final event)","(final html.Event event)");

            newLine = newLine.replaceFirst(new RegExp(r"^\s*?\*[^\w]*"),"/// ");

            newLine = newLine.replaceAllMapped(new RegExp("this\\.([^_]+)_"),
                (final Match m) => "_${m[1]}");

            newLine = newLine.replaceAllMapped(new RegExp("\\.([a-zA-Z]+)_+(\\.|\\()"),
                (final Match m) => "._${m[1]}${m[2]}");

            newLine = newLine.replaceFirst(new RegExp("^function "),"/*function*/\nclass ");
            newLine = newLine.replaceAll(", function()",", /*function*/ ()");
            newLine = newLine.replaceAll("(function()","( /*function*/ ()");
            newLine = newLine.replaceAll(", function(e)",", /*function*/ (e)");
            newLine = newLine.replaceAll("= function()","= /*function*/ ()");

            if (line.contains(".addEventListener('click',")) {
                contents.writeln("\n\t// .addEventListener('click', -> .onClick.listen(<MouseEvent>);");
                newLine = newLine.replaceFirst(".addEventListener('click',",".onClick.listen(");
            }
            if (line.contains(".addEventListener('scroll',")) {
                contents.writeln("\n\t// .addEventListener('scroll', -- .onScroll.listen(<Event>);");
                newLine = newLine.replaceFirst(".addEventListener('scroll',",".onScroll.listen(");
            }
            if (line.contains(".addEventListener('change',")) {
                contents.writeln("\n\t// .addEventListener('change', -- .onChange.listen(<Event>);");
                newLine = newLine.replaceFirst(".addEventListener('change',",".onChange.listen(");
            }
            if (line.contains(".addEventListener('focus',")) {
                contents.writeln("\n\t// .addEventListener('focus', -- .onFocus.listen(<Event>);");
                newLine = newLine.replaceFirst(".addEventListener('focus',",".onFocus.listen(");
            }
            if (line.contains(".addEventListener('blur',")) {
                contents.writeln("\n\t// .addEventListener('blur', -- .onBlur.listen(<Event>);");
                newLine = newLine.replaceFirst(".addEventListener('blur',",".onBlur.listen(");
            }
            if (line.contains(".addEventListener('mouseup',")) {
                contents.writeln("\n\t// .addEventListener('mouseup', -- .onMouseUp.listen(<MouseEvent>);");
                newLine = newLine.replaceFirst(".addEventListener('mouseup',",".onMouseUp.listen(");
            }
            if (line.contains(".addEventListener('mouseenter',")) {
                contents.writeln("\n\t// .addEventListener('mouseenter', -- .onMouseEnter.listen(<MouseEvent>);");
                newLine = newLine.replaceFirst(".addEventListener('mouseenter',",".onMouseEnter.listen(");
            }
            if (line.contains(".addEventListener('mouseleave',")) {
                contents.writeln("\n\t// .addEventListener('mouseleave', -- .onMouseLeave.listen(<MouseEvent>);");
                newLine = newLine.replaceFirst(".addEventListener('mouseleave',",".onMouseLeave.listen(");
            }

            if( line.contains(new RegExp("^function [^{]+{"))) {
                final String className = line.replaceAllMapped(new RegExp("^function ([^\\(]+)\\(.*"),
                    (final Match m) => "${m[1]}");

                contents.writeln("class $className {\n");

                String params = line.replaceAllMapped(new RegExp("^function [^\\(]+(([^\\)]+)).*"),
                    (final Match m) => "${m[1]}");
                params = params.replaceFirst("(","");

                final List<String> ptemp = new List<String>();
                params.split(',').forEach((final String element) {
                    ptemp.add("this.${element.trim()}");
                    contents.writeln("    final ${element.trim()};");
                });

                contents.writeln();
                contents.writeln("    $className(${ptemp.join(",")});");
                continue;
            }

            newLine = newLine.replaceAll("this.","");

            contents.writeln(newLine);
        }

        jsToConvert.writeAsStringSync(contents.toString().replaceAll(new RegExp("\n{2,}"),"\n\n"));
    }

    void _writeYaml(final String sampleName,final Config config) {
        Validate.notBlank(sampleName);
        Validate.notNull(config);

        //final Directory sampleDir = new Directory("${config.samplesdir}/${sampleName}");

        final File srcYaml = new File("${config.yamltemplate}");
        final File targetYaml = new File("${config.samplesdir}/${sampleName}/pubspec.yaml");
        if(targetYaml.existsSync()) {
            targetYaml.delete();
        }
        final String contents = srcYaml.readAsStringSync().replaceAll("{{samplename}}",sampleName);
        targetYaml.writeAsStringSync(contents);
    }

    void _writeIndexHtml(final Config config, final List<_LinkInfo> links) {
        Validate.notNull(config);
        Validate.notNull(links);


        final File srcIndexHtml = new File("${config.indextemplate}");
        final File targetIndexHtml = new File("${config.samplesdir}/localindex.html");
        if(targetIndexHtml.existsSync()) {
            targetIndexHtml.delete();
        }

        String contents = srcIndexHtml.readAsStringSync();
        contents = contents.replaceAll("{{lastupdate}}",new DateTime.now().toIso8601String());

        final StringBuffer buffer = new StringBuffer();
        links.forEach((final _LinkInfo linkinfo) {
            final String script = linkinfo.hasScript ? '<span class="script">[ main.dart ]</span>' : '';
            final String link = linkinfo.link.replaceFirst("${config.samplesdir}/","");

            buffer.writeln('            <li><a href="${link}">${linkinfo.sampleName}</a>$script</li>');
        });

        targetIndexHtml.writeAsString(contents.replaceFirst("{samples}",buffer.toString()));
        _logger.info("${targetIndexHtml.path} updated!");
    }

    void _addDartMainToIndexHTML(final File indexFile) {
        Validate.notNull(indexFile);
        Validate.isTrue(indexFile.existsSync());

        final List<String> lines = indexFile.readAsLinesSync();
        final StringBuffer buffer = new StringBuffer();

        bool commentLine = false;
        lines.forEach((final String line) {
            if(line.contains("<script")) {
                commentLine = true;
            }

            if(commentLine || (line.contains("<script") && line.contains("</script"))) {
                final String newline = "    <!-- ${line.trim()} -->";
                buffer.writeln(newline);
            }


            else if(line.contains("</body>")) {
                buffer.writeln('    <!-- start Autogenerated with gensamples.dart -->');
                buffer.writeln('    <script type="application/dart" src="main.dart"></script>');
                buffer.writeln('    <script type="text/javascript" src="packages/browser/dart.js"></script>');
                buffer.writeln('    <!-- end Autogenerated with gensamples.dart -->');
                buffer.writeln(line);
            }
            else {
                buffer.writeln(line);
            }

            if(line.contains("</script")) {
                commentLine = false;
            }

        });

        final String style = """\t<style>
            /* Autogenerated with gensamples.dart */
            div.loading { display: none; }
            body.mdl-upgrading > * { display: none; }
            body.mdl-upgrading div.loading { display: block; }\n\t</style>""";

        //final String newBody = '\t<body class="mdl-upgrading"> <div class="loading">Loading...</div>';

        String contents = buffer.toString();
        contents = contents.replaceFirst(new RegExp(r".*</head>"),"\n$style\n  </head>");

        //contents = contents.replaceFirst(new RegExp(r".*<body>"),newBody);
        contents = contents.replaceAllMapped(new RegExp(r'<body class="([^"]*)"[^>]*>'),
            (final Match m) => '<body class="${m[1]} mdl-upgrading">  <div class="loading">Loading...</div>');

        indexFile.writeAsStringSync(contents);
    }

    void _changeImportStatementInSassFile(final File scssFile,final String sampleName) {
        Validate.notNull(scssFile);
        Validate.isTrue(scssFile.existsSync());

        final List<String> lines = scssFile.readAsLinesSync();
        final StringBuffer contents = new StringBuffer();

        lines.forEach((final String line) {
            if(line.contains('@import "../mixins"')) {
                final String newLine = '@import "packages/mdl/assets/styles/mixins/mixins";';
                contents.writeln(newLine);

            } else if(line.contains(new RegExp("@import [\"']{1}\\\.{2}"))) {
                final String newline = line.replaceAllMapped(new RegExp("@import ([\"']){1}\\\.{2}/"),
                (final Match m) => "@import ${m[1]}packages/mdl/assets/styles/");

                contents.writeln(newline);

            } else if(line.contains(new RegExp("@import [\"']{1}"))) {
                final String newline = line.replaceAllMapped(new RegExp("@import ([\"']){1}"),
                    (final Match m) => "@import ${m[1]}packages/mdl/assets/styles/$sampleName/");

                contents.writeln(newline);
            }
            else {
                contents.writeln(line);
            }
        });

        scssFile.writeAsStringSync(contents.toString());
    }

    /// Goes through the files
    void _iterateThroughDirSync(final String dir,final List<String> foldersToExclude, void callback(final Directory dir)) {
        Validate.notNull(foldersToExclude);

        _logger.info("Scanning: $dir");

        // its OK if the path starts with packages but not if the path contains packages (avoid recursion)
        final RegExp regexp = new RegExp("^/*packages/*");

        final Directory directory = new Directory(dir);
        if (directory.existsSync()) {

            directory.listSync(recursive: false).where((final FileSystemEntity entity) {
                _logger.fine("Entity: ${entity.path}");

                if(entity is File) {
                    return false;
                }

//                bool isUsableFile = (entity != null && FileSystemEntity.isFileSync(entity.path) &&
//                    ( entity.path.endsWith(".dart") || entity.path.endsWith(".html") || entity.path.endsWith(".js"))
//                );
//
////                bool isUsableFile = (entity != null && FileSystemEntity.isFileSync(entity.path) &&
////                 entity.path.endsWith(".scss") && entity.path.contains("/_") &&
////                    (( entity.path.endsWith(".dart") || entity.path.endsWith(".html") || entity.path.endsWith(".js"))
////                );
//
//                if(!isUsableFile) {
//                    return false;
//                }

                for(final String folder in foldersToExclude) {
                    if(entity.path.contains(folder)) {
                        return false;
                    }
                }

                if(entity.path.contains("packages")) {
                    // return only true if the path starts!!!!! with packages
                    return entity.path.contains(regexp);
                }

                return true;

            }).any((final Directory dir) {
                //_logger.fine("  Found: ${file}");
                callback(dir);
            });
        }
    }

    void _iterateThroughExamplesDirSync(final String dir,final List<String> foldersToExclude, void callback(final Directory dir),{ final bool recursive: false }) {
        Validate.notNull(foldersToExclude);

        _logger.info("Scanning: $dir");

        // its OK if the path starts with packages but not if the path contains packages (avoid recursion)
        final RegExp regexp = new RegExp("^/*packages/*");

        final Directory directory = new Directory(dir);
        if (directory.existsSync()) {

            directory.listSync(recursive: recursive).where((final FileSystemEntity entity) {
                _logger.fine("Entity: ${entity}");

                if(!FileSystemEntity.isDirectorySync(entity.path)) {
                    return false;
                }

                // ignoriert _images...
                if(entity.path.contains("/_")) {
                    return false;
                }

                for(final String folder in foldersToExclude) {
                    if(entity.path.contains(folder)) {
                        return false;
                    }
                }

                if(entity.path.contains("packages")) {
                    // return only true if the path starts!!!!! with packages
                    return entity.path.contains(regexp);
                }

                return true;

            }).any((final Directory dir) {
                //_logger.fine("  Found: ${file}");
                callback(dir);
            });
        }
    }

    void _showUsage() {
        print("Usage: gensamples [options]");
        _parser.getUsage().split("\n").forEach((final String line) {
            print("    $line");
        });

        print("");
    }

    void _printSettings(final Map<String,String> settings) {
        Validate.notEmpty(settings);

        int getMaxKeyLength() {
            int length = 0;
            settings.keys.forEach((final String key) => length = max(length,key.length));
            return length;
        }

        final int maxKeyLeght = getMaxKeyLength();

        String prepareKey(final String key) {
            return "${key[0].toUpperCase()}${key.substring(1)}:".padRight(maxKeyLeght + 1);
        }

        print("Settings:");
        settings.forEach((final String key,final String value) {
            print("    ${prepareKey(key)} $value");
        });
    }

    static ArgParser _createOptions() {
        final ArgParser parser = new ArgParser()

            ..addFlag(_ARG_HELP,            abbr: 'h', negatable: false, help: "Shows this message")
            ..addFlag(_ARG_SETTINGS,        abbr: 's', negatable: false, help: "Prints settings")
            ..addFlag(_ARG_GENERATE,        abbr: 'g', negatable: false, help: "Generate samples")
            ..addFlag(_ARG_GEN_STYLEGUIDE,  abbr: 'y', negatable: false, help: "Generate styleguide")
            ..addFlag(_ARG_GENINDEX,        abbr: 'i', negatable: false, help: "Generate localindex.html")
            ..addFlag(_ARG_MK_BACKUP,       abbr: 'b', negatable: false, help: "Make backup")
            ..addFlag(_ARG_SHOW_DIRS,       abbr: 'd', negatable: false, help: "Show source-Dirs")
            ..addFlag(_ARG_MV_MDL,          abbr: 'm', negatable: false, help: "Move original MDL files to project")

            ..addOption(_ARG_LOGLEVEL,      abbr: 'v', help: "[ info | debug | warning ]")
            ;

        return parser;
    }

    void _configLogging(final String loglevel) {
        Validate.notBlank(loglevel);

        hierarchicalLoggingEnabled = false; // set this to true - its part of Logging SDK

        // now control the logging.
        // Turn off all logging first
        switch(loglevel) {
            case "fine":
            case "debug":
                Logger.root.level = Level.FINE;
                break;

            case "warning":
                Logger.root.level = Level.SEVERE;
                break;

            default:
                Logger.root.level = Level.INFO;
        }

        Logger.root.onRecord.listen(new LogPrintHandler(messageFormat: "%m"));
    }
}

/**
 * Defines default-configurations.
 * Most of these configs can be overwritten by commandline args.
 */
class Config {
    final Logger _logger = new Logger("gensamples.Config");

    static const String _KEY_SASS_DIR           = "sassdir";
    static const String _KEY_MDL_DIR            = "mdldir";
    static const String _KEY_SAMPLES_DIR        = "example";
    static const String _KEY_LOGLEVEL           = "loglevel";
    static const String _KEY_MK_BACKUP          = "mkbackup";
    static const String _KEY_MAIN_TEMPLATE      = "maintemplate";
    static const String _KEY_INDEX_TEMPLATE     = "indextemplate";
    static const String _KEY_YAML_TEMPLATE      = "yamltemplate";
    static const String _KEY_FOLDERS_TO_EXCLUDE = "excludefolder";
    static const String _KEY_PORT_BASE          = "portbase";
    static const String _KEY_JS_BASE            = "jsbase";

    final ArgResults _argResults;
    final Map<String,dynamic> _settings = new Map<String,dynamic>();

    Config(this._argResults) {

        _settings[_KEY_SASS_DIR]            = 'lib/assets/styles';
        _settings[_KEY_MDL_DIR]             = '/Volumes/Daten/DevLocal/DevDart/material-design-lite/src';
        _settings[_KEY_SAMPLES_DIR]         = 'example';
        _settings[_KEY_LOGLEVEL]            = 'info';
        _settings[_KEY_MK_BACKUP]           = false;
        _settings[_KEY_MAIN_TEMPLATE]       = "tool/templates/main.tmpl.dart";
        _settings[_KEY_INDEX_TEMPLATE]      = "tool/templates/index.tmpl.html";
        _settings[_KEY_YAML_TEMPLATE]       = "tool/templates/pubspec.tmpl.yaml";
        _settings[_KEY_FOLDERS_TO_EXCLUDE]  = "demo-images,demo,third_party";   // Liste durch , getrennt
        _settings[_KEY_PORT_BASE]           = "tool/portbase"; // Ziel für die konvertierten JS-Files
        _settings[_KEY_JS_BASE]             = "tool/jsbase"; // Basis für die JS-Files

        _overwriteSettingsWithArgResults();
    }

    List<String> get dirstoscan => _argResults.rest;

    String get loglevel => _settings[_KEY_LOGLEVEL];

    String get sassdir => _settings[_KEY_SASS_DIR];

    String get mdldir => _settings[_KEY_MDL_DIR];

    String get samplesdir => _settings[_KEY_SAMPLES_DIR];

    bool get mkbackup => _settings[_KEY_MK_BACKUP];

    String get maintemplate => _settings[_KEY_MAIN_TEMPLATE];

    String get indextemplate => _settings[_KEY_INDEX_TEMPLATE];

    String get yamltemplate => _settings[_KEY_YAML_TEMPLATE];

    String get folderstoexclude => _settings[_KEY_FOLDERS_TO_EXCLUDE];

    String get portbase => _settings[_KEY_PORT_BASE];

    String get jsbase => _settings[_KEY_JS_BASE];

    Map<String,String> get settings {
        final Map<String,String> settings = new Map<String,String>();

        settings["SASS-Dir"]                    = sassdir;
        settings["Samples-Dir"]                 = samplesdir;
        settings["MDL-Dir"]                     = mdldir;
        settings["loglevel"]                    = loglevel;
        settings["make backup"]                 = mkbackup ? "yes" : "no";
        settings["Main-Template"]               = maintemplate;
        settings["Index-Template"]              = indextemplate;
        settings["YAML-Template"]               = yamltemplate;
        settings["Folders to exclude"]          = folderstoexclude;
        settings["Base-Dir for js2Dart files"]  = portbase;
        settings["Base-Dir for ORIG JS files"]  = jsbase;

        if(dirstoscan.length > 0) {
            settings["Dirs to scan"] = dirstoscan.join(", ");
        }

        return settings;
    }

    // -- private -------------------------------------------------------------

    _overwriteSettingsWithArgResults() {

        /// Makes sure that path does not end with a /
        String checkPath(final String arg) {
            String path = arg;
            if(path.endsWith("/")) {
                path = path.replaceFirst(new RegExp("/\$"),"");
            }
            return path;
        }

        if(_argResults[Application._ARG_LOGLEVEL] != null) {
            _settings[_KEY_LOGLEVEL] = _argResults[Application._ARG_LOGLEVEL];
        }

        if(_argResults[Application._ARG_MK_BACKUP] != null) {
            _settings[_KEY_MK_BACKUP] = _argResults[Application._ARG_MK_BACKUP] as bool;
        }
    }
}

class _LinkInfo {
    final String sampleName;
    final String link;
    final bool hasScript;
    _LinkInfo(this.sampleName,this.link, this.hasScript);
}

void main(List<String> arguments) {
    final Application application = new Application();
    application.run( arguments );
}
