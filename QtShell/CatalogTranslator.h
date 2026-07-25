#pragma once

// The Qt shell's half of the shared string catalog.
//
// Translations are canonical in App/Resources/Localizable.xcstrings (the one
// place a human edits, both UIs); Scripts/gen-translations.py flattens that
// into QtShell/i18n/<lang>.json, which CMake compiles into :/i18n/. This
// QTranslator reads those maps directly.
//
// Why not .ts/.qm: lrelease/lupdate live in Qt Linguist (qttools), a build
// tool we would then have to install and version on macOS, Windows AND Linux
// — for a catalog we already generate. A QTranslator subclass is ~40 lines,
// needs no tooling, and keeps the call sites ordinary qsTr()/tr(). The cost
// is that lupdate can't extract strings; Scripts/check-translations.sh scans
// for un-wrapped literals instead, which also catches what lupdate would.
//
// Lookup is by source text alone, ignoring Qt's context (class / QML file):
// the catalog is keyed on the English string, exactly as the macOS side keys
// Localizable.xcstrings, so one entry serves both UIs and can't drift.

#include <QCoreApplication>
#include <QFile>
#include <QHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QString>
#include <QStringList>
#include <QTranslator>

// No Q_OBJECT: this subclass adds no signals, slots or properties, so it
// needs no meta-object and stays header-only.
class CatalogTranslator : public QTranslator {
public:
    using QTranslator::QTranslator;

    // Loads :/i18n/<tag>.json. Returns false (leaving this translator empty,
    // so English shows through) when the language has no catalog.
    bool loadCatalog(const QString &tag) {
        map_.clear();
        QFile file(QStringLiteral(":/i18n/%1.json").arg(tag));
        if (!file.open(QIODevice::ReadOnly)) return false;
        const QJsonObject obj =
            QJsonDocument::fromJson(file.readAll()).object();
        for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
            const QString value = it.value().toString();
            if (!value.isEmpty()) map_.insert(it.key(), value);
        }
        return !map_.isEmpty();
    }

    // The language tags the catalog ships, most specific first, for the
    // given locale: pt_BR → "pt-BR", "pt"; zh_CN → "zh-Hans", "zh"; de_DE →
    // "de". Script matters for Chinese, where the language code alone can't
    // choose between Hans and Hant.
    static QStringList candidateTags(const QLocale &locale) {
        QStringList tags;
        tags << QString(locale.name()).replace(QLatin1Char('_'),
                                               QLatin1Char('-'));
        if (locale.script() != QLocale::AnyScript) {
            tags << QLocale::languageToCode(locale.language())
                        + QLatin1Char('-')
                        + QLocale::scriptToCode(locale.script());
        }
        tags << QLocale::languageToCode(locale.language());
        tags.removeAll(QString());
        tags.removeDuplicates();
        return tags;
    }

    QString translate(const char *context, const char *sourceText,
                      const char *disambiguation = nullptr,
                      int n = -1) const override {
        Q_UNUSED(context)
        Q_UNUSED(disambiguation)
        Q_UNUSED(n)
        if (!sourceText) return QString();
        // A miss returns a null QString, which is Qt's signal to fall back
        // to the source text — an English word beats an empty control.
        return map_.value(QString::fromUtf8(sourceText));
    }

    bool isEmpty() const override { return map_.isEmpty(); }

private:
    QHash<QString, QString> map_;
};
