import AVFoundation
import UIKit

extension VideoPlayerView {
    func setChapters(_ chapters: [VideoChapter]) {
        self.chapters = chapters
            .filter { $0.startTime.isFinite && $0.startTime >= 0 }
            .sorted { $0.startTime < $1.startTime }
        refreshChapterSeekBar()
        updateChapterTitle(at: player?.currentTime().seconds ?? 0)
    }

    func refreshChapterSeekBar() {
        guard duration.isFinite, duration > 0 else {
            seekBar.setChapterBreaks([])
            return
        }
        seekBar.setChapterBreaks(chapters.map { $0.startTime / duration })
    }

    func setupChapterTitle() {
        chapterTitleContainer.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        chapterTitleContainer.layer.cornerRadius = 14
        chapterTitleContainer.isHidden = true
        chapterTitleContainer.isUserInteractionEnabled = false
        chapterTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        chapterTitleLabel.textColor = .white
        chapterTitleLabel.lineBreakMode = .byTruncatingTail
        chapterTitleContainer.translatesAutoresizingMaskIntoConstraints = false
        chapterTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(chapterTitleContainer)
        chapterTitleContainer.addSubview(chapterTitleLabel)
        activateChapterTitleConstraints()
    }

    private func activateChapterTitleConstraints() {
        NSLayoutConstraint.activate([
            chapterTitleContainer.leadingAnchor.constraint(equalTo: seekBar.leadingAnchor),
            chapterTitleContainer.trailingAnchor.constraint(
                lessThanOrEqualTo: seekBar.trailingAnchor
            ),
            chapterTitleContainer.bottomAnchor.constraint(equalTo: seekBar.topAnchor, constant: -2),
            chapterTitleContainer.heightAnchor.constraint(equalToConstant: 28),
            chapterTitleLabel.leadingAnchor.constraint(
                equalTo: chapterTitleContainer.leadingAnchor, constant: 10
            ),
            chapterTitleLabel.trailingAnchor.constraint(
                equalTo: chapterTitleContainer.trailingAnchor, constant: -10
            ),
            chapterTitleLabel.centerYAnchor.constraint(equalTo: chapterTitleContainer.centerYAnchor)
        ])
    }

    func updateChapterTitle(at seconds: Double) {
        let title = seconds.isFinite ? chapters.last {
            $0.startTime <= seconds
        }?.title : nil
        if chapterTitleLabel.text != title {
            chapterTitleLabel.text = title
        }
        chapterTitleContainer.isHidden = title?.isEmpty != false
    }
}
