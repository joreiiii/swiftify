#include "ViewRig.h"
#include "app/Fonts.h"
#include <QQmlComponent>
#include <QLineF>
#include <QtQml/qqmlextensionplugin.h>
Q_IMPORT_QML_PLUGIN(SwiftifyPlugin)
using namespace swiftify;
class SegmentedControlTest : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() { fonts::loadIconFont(); fonts::loadInterfaceFont(); }
    void selectionSurvivesReparenting() {
        testing::ViewRig rig;
        rig.settings.setReduceMotion(true);
        QQmlComponent component(&rig.engine);
        component.setData("import QtQuick\nimport Swiftify\nSegmentedControl { currentIndex: 1; segments: [Segment { text: 'Normal' }, Segment { text: 'Circular' }] }", QUrl());
        std::unique_ptr<QObject> root(component.create());
        QVERIFY2(root, qPrintable(component.errorString()));
        auto *item = qobject_cast<QQuickItem *>(root.get());
        item->setParentItem(rig.window->contentItem());
        auto *indicator = root->findChild<QQuickItem *>("selectionIndicator");
        QVERIFY(indicator);
        for (int cycle = 0; cycle < 3; ++cycle) {
            QTRY_VERIFY(indicator->isVisible() && indicator->width() > 0);
            QCOMPARE(root->property("currentIndex").toInt(), 1);
            item->setParentItem(nullptr);
            testing::ViewRig::settle();
            item->setParentItem(rig.window->contentItem());
            testing::ViewRig::settle();
        }
        QTRY_VERIFY(indicator->isVisible() && indicator->width() > 0);
    }
    void selectionSurvivesSettingsNavigation() {
        testing::ViewRig rig;
        rig.settings.setReduceMotion(true);
        const auto pages = rig.show(QStringLiteral("SettingsView"));
        QVERIFY(pages);
        for (bool circular : {false, true}) {
            rig.settings.setCircularVisualizer(circular);
            for (int cycle = 0; cycle < 2; ++cycle) {
                pages->setProperty("page", 1);
                testing::ViewRig::settle();
                pages->setProperty("page", 0);
                testing::ViewRig::settle();
                rig.render();
                for (const QString &label : {QStringLiteral("Style"), QStringLiteral("Shape")}) {
                    QObject *choice = nullptr;
                    for (QObject *candidate : pages->findChildren<QObject *>()) {
                        if (candidate->property("text").toString() == label
                            && candidate->metaObject()->indexOfProperty("segments") >= 0) {
                            choice = candidate;
                            break;
                        }
                    }
                    QVERIFY(choice);
                    auto *indicator = choice->findChild<QQuickItem *>("selectionIndicator");
                    QVERIFY(indicator);
                    QTRY_VERIFY(indicator->isVisible() && indicator->width() > 0);
                    QVERIFY(indicator->property("target").value<QQuickItem *>());
                    if (label == QStringLiteral("Style")) QCOMPARE(choice->property("currentIndex").toInt(), circular ? 1 : 0);
                }
            }
        }
        const QString preview = qEnvironmentVariable("SWIFTIFY_SEGMENTS_PREVIEW");
        if (!preview.isEmpty()) QVERIFY(rig.render().save(preview));
    }

};
QTEST_MAIN(SegmentedControlTest)
#include "tst_segmented.moc"
