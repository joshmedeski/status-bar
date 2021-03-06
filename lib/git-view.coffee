_ = require "underscore-plus"
{CompositeDisposable, GitRepositoryAsync} = require "atom"

class GitView extends HTMLElement
  initialize: ->
    @classList.add('git-view')

    @createBranchArea()
    @createCommitsArea()
    @createStatusArea()

    @updateStatusPromise = Promise.resolve()
    @updateBranchPromise = Promise.resolve()

    @activeItemSubscription = atom.workspace.onDidChangeActivePaneItem =>
      @subscribeToActiveItem()
    @projectPathSubscription = atom.project.onDidChangePaths =>
      @subscribeToRepositories()
    @subscribeToRepositories()
    @subscribeToActiveItem()

  createBranchArea: ->
    @branchArea = document.createElement('div')
    @branchArea.classList.add('git-branch', 'inline-block')
    @appendChild(@branchArea)

    branchIcon = document.createElement('span')
    branchIcon.classList.add('icon', 'icon-git-branch')
    @branchArea.appendChild(branchIcon)

    @branchLabel = document.createElement('span')
    @branchLabel.classList.add('branch-label')
    @branchArea.appendChild(@branchLabel)

  createCommitsArea: ->
    @commitsArea = document.createElement('div')
    @commitsArea.classList.add('git-commits', 'inline-block')
    @appendChild(@commitsArea)

    @commitsAhead = document.createElement('span')
    @commitsAhead.classList.add('icon', 'icon-arrow-up', 'commits-ahead-label')
    @commitsArea.appendChild(@commitsAhead)

    @commitsBehind = document.createElement('span')
    @commitsBehind.classList.add('icon', 'icon-arrow-down', 'commits-behind-label')
    @commitsArea.appendChild(@commitsBehind)

  createStatusArea: ->
    @gitStatus = document.createElement('div')
    @gitStatus.classList.add('git-status', 'inline-block')
    @appendChild(@gitStatus)

    @gitStatusIcon = document.createElement('span')
    @gitStatusIcon.classList.add('icon')
    @gitStatus.appendChild(@gitStatusIcon)

  subscribeToActiveItem: ->
    activeItem = @getActiveItem()

    @savedSubscription?.dispose()
    @savedSubscription = activeItem?.onDidSave? => @update()

    @update()

  subscribeToRepositories: ->
    @repositorySubscriptions?.dispose()
    @repositorySubscriptions = new CompositeDisposable

    for repo in atom.project.getRepositories() when repo?
      @repositorySubscriptions.add repo.async.onDidChangeStatus ({path, status}) =>
        @update() if path is @getActiveItemPath()
      @repositorySubscriptions.add repo.async.onDidChangeStatuses =>
        @update()

  destroy: ->
    @activeItemSubscription?.dispose()
    @projectPathSubscription?.dispose()
    @savedSubscription?.dispose()
    @repositorySubscriptions?.dispose()
    @branchTooltipDisposable?.dispose()
    @commitsAheadTooltipDisposable?.dispose()
    @commitsBehindTooltipDisposable?.dispose()
    @statusTooltipDisposable?.dispose()

  getActiveItemPath: ->
    @getActiveItem()?.getPath?()

  getRepositoryForActiveItem: ->
    [rootDir] = atom.project.relativizePath(@getActiveItemPath())
    rootDirIndex = atom.project.getPaths().indexOf(rootDir)
    if rootDirIndex >= 0
      atom.project.getRepositories()[rootDirIndex]?.async
    else
      for repo in atom.project.getRepositories() when repo
        return repo.async

  getActiveItem: ->
    atom.workspace.getActivePaneItem()

  update: ->
    repo = @getRepositoryForActiveItem()
    @updateBranchText(repo)
    @updateAheadBehindCount(repo)
    @updateStatusText(repo)

  updateBranchText: (repo) ->
    @updateBranchPromise = @updateBranchPromise.then =>
      if @showGitInformation(repo)
        repo?.getShortHead(@getActiveItemPath())
          .then (head) =>
            @branchLabel.textContent = head
            @branchArea.style.display = '' if head
            @branchTooltipDisposable?.dispose()
            @branchTooltipDisposable = atom.tooltips.add @branchArea, title: "On branch #{head}"
          .catch (e) ->
            # Since the update branch calls are effectively queued using the
            # `updateBranchPromise`, we could end up trying to refresh after the
            # repo's been destroyed.
            if e.name is GitRepositoryAsync.DestroyedErrorName
              return null
            else
              return Promise.reject(e)
          .catch (e) ->
            console.error('Error getting short head:')
            console.error(e)
      else
        @branchArea.style.display = 'none'

  showGitInformation: (repo) ->
    return false unless repo?

    if itemPath = @getActiveItemPath()
      atom.project.contains(itemPath)
    else
      not @getActiveItem()?

  updateAheadBehindCount: (repo) ->
    unless @showGitInformation(repo)
      @commitsArea.style.display = 'none'
      return

    itemPath = @getActiveItemPath()
    repo.getCachedUpstreamAheadBehindCount(itemPath).then ({ahead, behind}) =>
      if ahead > 0
        @commitsAhead.textContent = ahead
        @commitsAhead.style.display = ''
        @commitsAheadTooltipDisposable?.dispose()
        @commitsAheadTooltipDisposable = atom.tooltips.add @commitsAhead, title: "#{_.pluralize(ahead, 'commit')} ahead of upstream"
      else
        @commitsAhead.style.display = 'none'

      if behind > 0
        @commitsBehind.textContent = behind
        @commitsBehind.style.display = ''
        @commitsBehindTooltipDisposable?.dispose()
        @commitsBehindTooltipDisposable = atom.tooltips.add @commitsBehind, title: "#{_.pluralize(behind, 'commit')} behind upstream"
      else
        @commitsBehind.style.display = 'none'

      if ahead > 0 or behind > 0
        @commitsArea.style.display = ''
      else
        @commitsArea.style.display = 'none'

  clearStatus: ->
    @gitStatusIcon.classList.remove('icon-diff-modified', 'status-modified', 'icon-diff-added', 'status-added', 'icon-diff-ignored', 'status-ignored')

  updateAsNewFile: ->
    @clearStatus()

    @gitStatusIcon.classList.add('icon-diff-added', 'status-added')
    if textEditor = atom.workspace.getActiveTextEditor()
      @gitStatusIcon.textContent = "+#{textEditor.getLineCount()}"
      @updateTooltipText("#{_.pluralize(textEditor.getLineCount(), 'line')} in this new file not yet committed")
    else
      @gitStatusIcon.textContent = ''
      @updateTooltipText()

    @gitStatus.style.display = ''

    Promise.resolve()

  updateAsModifiedFile: (repo, path) ->
    repo.getDiffStats(path)
      .then (stats) =>
        @clearStatus()

        @gitStatusIcon.classList.add('icon-diff-modified', 'status-modified')
        if stats.added and stats.deleted
          @gitStatusIcon.textContent = "+#{stats.added}, -#{stats.deleted}"
          @updateTooltipText("#{_.pluralize(stats.added, 'line')} added and #{_.pluralize(stats.deleted, 'line')} deleted in this file not yet committed")
        else if stats.added
          @gitStatusIcon.textContent = "+#{stats.added}"
          @updateTooltipText("#{_.pluralize(stats.added, 'line')} added to this file not yet committed")
        else if stats.deleted
          @gitStatusIcon.textContent = "-#{stats.deleted}"
          @updateTooltipText("#{_.pluralize(stats.deleted, 'line')} deleted from this file not yet committed")
        else
          @gitStatusIcon.textContent = ''
          @updateTooltipText()

        @gitStatus.style.display = ''

  updateAsIgnoredFile: ->
    @clearStatus()

    @gitStatusIcon.classList.add('icon-diff-ignored',  'status-ignored')
    @gitStatusIcon.textContent = ''
    @gitStatus.style.display = ''
    @updateTooltipText("File is ignored by git")

    Promise.resolve()

  updateTooltipText: (text) ->
    @statusTooltipDisposable?.dispose()
    if text
      @statusTooltipDisposable = atom.tooltips.add @gitStatusIcon, title: text

  updateStatusText: (repo) ->
    hideStatus = =>
      @clearStatus()
      @gitStatus.style.display = 'none'

    itemPath = @getActiveItemPath()
    @updateStatusPromise = @updateStatusPromise.then =>
      if @showGitInformation(repo) and itemPath?
        repo?.getCachedPathStatus(itemPath)
          .then (status = 0) =>
            if repo?.isStatusNew(status)
              return @updateAsNewFile()

            if repo?.isStatusModified(status)
              return @updateAsModifiedFile(repo, itemPath)

            repo?.isPathIgnored(itemPath).then (ignored) =>
              if ignored
                @updateAsIgnoredFile()
              else
                hideStatus()
                Promise.resolve()
          .catch (e) ->
            # Since the update status calls are effectively queued using the
            # `updateStatusPromise`, we could end up trying to refresh after the
            # repo's been destroyed.
            if e.name is GitRepositoryAsync.DestroyedErrorName
              return null
            else
              return Promise.reject(e)
          .catch (e) ->
            console.error('Error getting status for ' + itemPath + ':')
            console.error(e)
      else
        hideStatus()

module.exports = document.registerElement('status-bar-git', prototype: GitView.prototype, extends: 'div')
